// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * ablspi - SPI driver for CM <-> XMOS communication on the Ableton Move
 *
 * Clean-room re-implementation of Ableton AG's ablspi.ko driver against the
 * ABI documented in Ableton's GPL-2.0-or-later user-space "move-spi" library
 * (https://github.com/Ableton/jack2-move-move). Targets Linux 6.6 LTS on
 * Raspberry Pi Compute Module 5 (BCM2712) carriers wired to mirror the CM4
 * pinout: SPI0 chip-select 0 + a GPIO line ("irq-gpio") asserted by the XMOS
 * MCU whenever it has a frame ready to exchange.
 *
 * Wire protocol summary (4 KB mmap'd shared page):
 *   offset 0    .. 2047 : CM -> XMOS output region (MIDI / display / audio)
 *   offset 2048 .. 4095 : XMOS -> CM input  region (MIDI / display / audio)
 *
 * Hot path is a single ioctl, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE(size):
 *   1. block until the XMOS GPIO IRQ fires (XMOS ready)
 *   2. submit one duplex spi_async() of `size' bytes (tx_buf=page+0,
 *      rx_buf=page+2048)
 *   3. wait for the SPI completion and return
 *
 * /proc/ableton/ablspi/{irq_count,spi_tx_time,failed_send_count} expose runtime
 * statistics for parity with the original driver.
 */

#include <linux/atomic.h>
#include <linux/cdev.h>
#include <linux/completion.h>
#include <linux/dma-mapping.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/gpio/consumer.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/ioctl.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_gpio.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/spi/spi.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#define ABLSPI_DRV_NAME		"ablspi"
#define ABLSPI_CLASS_NAME	"ablspi"
#define ABLSPI_PROC_PARENT	"ableton"
#define ABLSPI_PROC_DIR		"ablspi"
#define ABLSPI_MAX_DEVICES	4

/* Single page shared with user space via mmap; split in half for tx/rx. */
#define ABLSPI_BUFFER_SIZE	PAGE_SIZE
#define ABLSPI_HALF		(ABLSPI_BUFFER_SIZE / 2)

/* Per-frame transport defaults from Ableton's move-spi library. */
#define ABLSPI_DEFAULT_FRAME	768u
#define ABLSPI_DEFAULT_HZ	20000000u
#define ABLSPI_MIN_HZ		100000u
#define ABLSPI_MAX_HZ		125000000u

/*
 * Ioctl command numbers. These are plain integers (no _IO() encoding) to match
 * the on-the-wire ABI used by the stock Move user-space binaries. Do not
 * renumber - the constants are baked into MoveLauncher / MoveOriginal /
 * MoveXmosCli / JackMoveDriver.
 */
enum {
	ABLSPI_FILL_TX_BUFFER			= 0,
	ABLSPI_FILL_RX_BUFFER			= 1,
	ABLSPI_READ_BUFFER			= 2,
	ABLSPI_SEND_MESSAGE			= 3,
	ABLSPI_SEND_MESSAGE_AND_WAIT		= 4,
	ABLSPI_WAIT_AND_SEND_MESSAGE		= 5,
	ABLSPI_GET_STATE			= 6,
	ABLSPI_CAN_SEND				= 7,
	ABLSPI_SET_MESSAGE_SIZE			= 8,
	ABLSPI_GET_MESSAGE_SIZE			= 9,
	ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE	= 10,
	ABLSPI_SET_SPEED			= 11,
	ABLSPI_GET_SPEED			= 12,
};

/*
 * Exposed via ABLSPI_GET_STATE. Layout is stable so user space can read the
 * counters without re-opening /proc each frame.
 */
struct ablspi_state {
	__u32 in_transfer;
	__u32 gpio_setup;
	__u32 irq_count;
	__u32 failed_send_count;
	__u32 message_size;
	__u32 speed_hz;
	__u64 last_tx_ns;
};

struct ablspi_dev {
	struct spi_device	*spi;
	struct device		*classdev;
	struct cdev		cdev;
	dev_t			devt;
	int			minor;
	int			bus_num;
	int			chip_select;

	/* Shared 4 KB page; tx_buf=base, rx_buf=base+HALF. */
	void			*buffer;
	unsigned long		buffer_pfn;

	struct mutex		lock;		/* serialises transfer state */
	atomic_t		in_transfer;
	atomic_t		open_count;
	u32			message_size;
	u32			speed_hz;

	struct gpio_desc	*irq_gpio;
	int			irq;
	bool			gpio_setup;
	char			irq_name[32];
	struct completion	irq_event;

	struct spi_transfer	xfer;
	struct spi_message	msg;
	struct completion	xfer_done;
	int			xfer_status;

	/* Statistics */
	atomic_t		irq_count;
	atomic_t		failed_send_count;
	ktime_t			tx_start;
	atomic64_t		last_tx_ns;
	atomic64_t		total_tx_ns;
	atomic64_t		max_tx_ns;

	struct proc_dir_entry	*proc_dev_dir;
};

/* ---------- module-wide state ---------- */

static dev_t			ablspi_devt_base;
static struct class		*ablspi_class;
static struct proc_dir_entry	*ablspi_proc_parent;	/* /proc/ableton */
static struct proc_dir_entry	*ablspi_proc_dir;	/* /proc/ableton/ablspi */
static DEFINE_MUTEX(ablspi_minor_lock);
static DECLARE_BITMAP(ablspi_minor_map, ABLSPI_MAX_DEVICES);

static int ablspi_minor_alloc(void)
{
	int minor;

	mutex_lock(&ablspi_minor_lock);
	minor = find_first_zero_bit(ablspi_minor_map, ABLSPI_MAX_DEVICES);
	if (minor >= ABLSPI_MAX_DEVICES) {
		mutex_unlock(&ablspi_minor_lock);
		return -ENOSPC;
	}
	set_bit(minor, ablspi_minor_map);
	mutex_unlock(&ablspi_minor_lock);
	return minor;
}

static void ablspi_minor_free(int minor)
{
	if (minor < 0 || minor >= ABLSPI_MAX_DEVICES)
		return;
	mutex_lock(&ablspi_minor_lock);
	clear_bit(minor, ablspi_minor_map);
	mutex_unlock(&ablspi_minor_lock);
}

/* ---------- IRQ + SPI transfer plumbing ---------- */

static irqreturn_t ablspi_gpio_isr(int irq, void *data)
{
	struct ablspi_dev *adev = data;

	atomic_inc(&adev->irq_count);
	complete(&adev->irq_event);
	return IRQ_HANDLED;
}

static void ablspi_xfer_complete(void *context)
{
	struct ablspi_dev *adev = context;
	s64 now_ns, dur;

	now_ns = ktime_to_ns(ktime_get());
	dur = now_ns - ktime_to_ns(adev->tx_start);
	if (dur < 0)
		dur = 0;

	atomic64_set(&adev->last_tx_ns, dur);
	atomic64_add(dur, &adev->total_tx_ns);
	if (dur > atomic64_read(&adev->max_tx_ns))
		atomic64_set(&adev->max_tx_ns, dur);

	adev->xfer_status = adev->msg.status;
	complete(&adev->xfer_done);
}

/* Submit one duplex frame; does not wait for completion. */
static int ablspi_submit(struct ablspi_dev *adev, u32 size)
{
	int ret;

	if (size == 0 || size > ABLSPI_HALF) {
		dev_warn(&adev->spi->dev, "message size not in range\n");
		return -EINVAL;
	}

	if (atomic_cmpxchg(&adev->in_transfer, 0, 1) != 0) {
		dev_warn(&adev->spi->dev,
			 "tried to start transfer while in_transfer!\n");
		return -EBUSY;
	}

	memset(&adev->xfer, 0, sizeof(adev->xfer));
	adev->xfer.tx_buf	= adev->buffer;
	adev->xfer.rx_buf	= adev->buffer + ABLSPI_HALF;
	adev->xfer.len		= size;
	adev->xfer.speed_hz	= adev->speed_hz;
	adev->xfer.bits_per_word = 8;

	spi_message_init(&adev->msg);
	spi_message_add_tail(&adev->xfer, &adev->msg);
	adev->msg.complete = ablspi_xfer_complete;
	adev->msg.context  = adev;

	reinit_completion(&adev->xfer_done);
	adev->xfer_status = 0;
	adev->tx_start = ktime_get();

	ret = spi_async(adev->spi, &adev->msg);
	if (ret) {
		atomic_inc(&adev->failed_send_count);
		atomic_set(&adev->in_transfer, 0);
		dev_err_ratelimited(&adev->spi->dev,
				    "spi_async failed: %d\n", ret);
		return ret;
	}
	return 0;
}

/* Wait for the SPI completion previously armed by ablspi_submit(). */
static int ablspi_wait_for_xfer(struct ablspi_dev *adev)
{
	int ret;

	ret = wait_for_completion_interruptible(&adev->xfer_done);
	atomic_set(&adev->in_transfer, 0);
	if (ret)
		return ret;	/* -ERESTARTSYS on signal */
	return adev->xfer_status;
}

/* Wait until the XMOS GPIO IRQ has fired at least once since the last wait. */
static int ablspi_wait_for_irq(struct ablspi_dev *adev)
{
	int ret;

	if (!adev->gpio_setup) {
		dev_warn(&adev->spi->dev,
			 "gpio irq not set up, but attempted to wait for it!\n");
		return -ENODEV;
	}

	if (atomic_read(&adev->in_transfer)) {
		dev_warn(&adev->spi->dev,
			 "tried to wait for IRQ while being in_transfer!\n");
		return -EBUSY;
	}

	ret = wait_for_completion_interruptible(&adev->irq_event);
	if (ret)
		return ret;	/* -ERESTARTSYS on signal */

	reinit_completion(&adev->irq_event);
	return 0;
}

/* ---------- file operations ---------- */

static int ablspi_open(struct inode *inode, struct file *filp)
{
	struct ablspi_dev *adev = container_of(inode->i_cdev,
					       struct ablspi_dev, cdev);

	if (!adev->buffer)
		return -ENOMEM;

	filp->private_data = adev;
	atomic_inc(&adev->open_count);
	stream_open(inode, filp);
	return 0;
}

static int ablspi_release(struct inode *inode, struct file *filp)
{
	struct ablspi_dev *adev = filp->private_data;

	atomic_dec(&adev->open_count);
	return 0;
}

/*
 * read() returns up to `len' bytes from the rx half of the shared buffer
 * starting at *off. Lets test harnesses and the legacy pre-mmap path see
 * the inbound frame without setting up mmap.
 */
static ssize_t ablspi_read(struct file *filp, char __user *buf,
			   size_t len, loff_t *off)
{
	struct ablspi_dev *adev = filp->private_data;
	loff_t pos = *off;
	size_t avail;

	if (pos < 0 || pos >= ABLSPI_HALF)
		return 0;
	avail = ABLSPI_HALF - (size_t)pos;
	if (len > avail)
		len = avail;
	if (copy_to_user(buf, adev->buffer + ABLSPI_HALF + pos, len))
		return -EFAULT;
	*off = pos + len;
	return len;
}

/*
 * write() pushes up to `len' bytes into the tx half of the shared buffer at
 * *off. Mirror of read(), for the same legacy/test path.
 */
static ssize_t ablspi_write(struct file *filp, const char __user *buf,
			    size_t len, loff_t *off)
{
	struct ablspi_dev *adev = filp->private_data;
	loff_t pos = *off;
	size_t avail;

	if (pos < 0 || pos >= ABLSPI_HALF)
		return -ENOSPC;
	avail = ABLSPI_HALF - (size_t)pos;
	if (len > avail)
		len = avail;
	if (copy_from_user(adev->buffer + pos, buf, len))
		return -EFAULT;
	*off = pos + len;
	return len;
}

static int ablspi_mmap(struct file *filp, struct vm_area_struct *vma)
{
	struct ablspi_dev *adev = filp->private_data;
	unsigned long size = vma->vm_end - vma->vm_start;

	if (vma->vm_pgoff != 0)
		return -EINVAL;
	if (size > ABLSPI_BUFFER_SIZE)
		return -EINVAL;

	vm_flags_set(vma, VM_DONTEXPAND | VM_DONTDUMP);

	if (remap_pfn_range(vma, vma->vm_start, adev->buffer_pfn,
			    size, vma->vm_page_prot))
		return -EAGAIN;

	return 0;
}

/* ---------- ioctl handlers ---------- */

static long ablspi_do_fill_tx(struct ablspi_dev *adev, unsigned long arg)
{
	void __user *u = (void __user *)arg;

	if (!u)
		return -EFAULT;
	if (copy_from_user(adev->buffer, u, adev->message_size))
		return -EFAULT;
	return 0;
}

static long ablspi_do_fill_rx(struct ablspi_dev *adev, unsigned long arg)
{
	void __user *u = (void __user *)arg;

	if (!u)
		return -EFAULT;
	if (copy_from_user(adev->buffer + ABLSPI_HALF, u, adev->message_size))
		return -EFAULT;
	return 0;
}

static long ablspi_do_read_buffer(struct ablspi_dev *adev, unsigned long arg)
{
	void __user *u = (void __user *)arg;

	if (!u)
		return -EFAULT;
	if (copy_to_user(u, adev->buffer + ABLSPI_HALF, adev->message_size))
		return -EFAULT;
	return 0;
}

static long ablspi_do_send_message(struct ablspi_dev *adev)
{
	return ablspi_submit(adev, adev->message_size);
}

static long ablspi_do_send_and_wait(struct ablspi_dev *adev)
{
	int ret;

	ret = ablspi_submit(adev, adev->message_size);
	if (ret)
		return ret;
	return ablspi_wait_for_xfer(adev);
}

static long ablspi_do_wait_and_send(struct ablspi_dev *adev)
{
	int ret;

	ret = ablspi_wait_for_irq(adev);
	if (ret)
		return ret;
	ret = ablspi_submit(adev, adev->message_size);
	if (ret)
		return ret;
	return ablspi_wait_for_xfer(adev);
}

static long ablspi_do_wait_and_send_sized(struct ablspi_dev *adev,
					  unsigned long size)
{
	int ret;

	if (size == 0 || size > ABLSPI_HALF) {
		dev_warn(&adev->spi->dev, "message size not in range\n");
		return -EINVAL;
	}

	adev->message_size = (u32)size;

	ret = ablspi_wait_for_irq(adev);
	if (ret)
		return ret;
	ret = ablspi_submit(adev, adev->message_size);
	if (ret)
		return ret;
	return ablspi_wait_for_xfer(adev);
}

static long ablspi_do_get_state(struct ablspi_dev *adev, unsigned long arg)
{
	struct ablspi_state st = {
		.in_transfer       = (u32)atomic_read(&adev->in_transfer),
		.gpio_setup        = adev->gpio_setup ? 1 : 0,
		.irq_count         = (u32)atomic_read(&adev->irq_count),
		.failed_send_count = (u32)atomic_read(&adev->failed_send_count),
		.message_size      = adev->message_size,
		.speed_hz          = adev->speed_hz,
		.last_tx_ns        = (u64)atomic64_read(&adev->last_tx_ns),
	};
	void __user *u = (void __user *)arg;

	if (!u)
		return -EFAULT;
	if (copy_to_user(u, &st, sizeof(st)))
		return -EFAULT;
	return 0;
}

static long ablspi_do_can_send(struct ablspi_dev *adev)
{
	return atomic_read(&adev->in_transfer) ? 0 : 1;
}

static long ablspi_do_set_message_size(struct ablspi_dev *adev,
				       unsigned long arg)
{
	if (arg == 0 || arg > ABLSPI_HALF) {
		dev_warn(&adev->spi->dev, "message size not in range\n");
		return -EINVAL;
	}
	adev->message_size = (u32)arg;
	return 0;
}

static long ablspi_do_get_message_size(struct ablspi_dev *adev,
				       unsigned long arg)
{
	u32 __user *u = (u32 __user *)arg;

	if (!u)
		return -EFAULT;
	return put_user(adev->message_size, u);
}

static long ablspi_do_set_speed(struct ablspi_dev *adev, unsigned long arg)
{
	struct spi_device *spi = adev->spi;
	u32 old, hz = (u32)arg;
	int ret;

	if (hz < ABLSPI_MIN_HZ || hz > ABLSPI_MAX_HZ) {
		dev_warn(&spi->dev, "speed not in range\n");
		return -EINVAL;
	}

	old = spi->max_speed_hz;
	spi->max_speed_hz = hz;
	ret = spi_setup(spi);
	if (ret) {
		spi->max_speed_hz = old;
		(void)spi_setup(spi);
		return ret;
	}
	adev->speed_hz = hz;
	return 0;
}

static long ablspi_do_get_speed(struct ablspi_dev *adev, unsigned long arg)
{
	u32 __user *u = (u32 __user *)arg;

	if (!u)
		return -EFAULT;
	return put_user(adev->speed_hz, u);
}

static long ablspi_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	struct ablspi_dev *adev = filp->private_data;
	long ret;

	mutex_lock(&adev->lock);

	switch (cmd) {
	case ABLSPI_FILL_TX_BUFFER:
		ret = ablspi_do_fill_tx(adev, arg);
		break;
	case ABLSPI_FILL_RX_BUFFER:
		ret = ablspi_do_fill_rx(adev, arg);
		break;
	case ABLSPI_READ_BUFFER:
		ret = ablspi_do_read_buffer(adev, arg);
		break;
	case ABLSPI_SEND_MESSAGE:
		ret = ablspi_do_send_message(adev);
		break;
	case ABLSPI_SEND_MESSAGE_AND_WAIT:
		ret = ablspi_do_send_and_wait(adev);
		break;
	case ABLSPI_WAIT_AND_SEND_MESSAGE:
		ret = ablspi_do_wait_and_send(adev);
		break;
	case ABLSPI_GET_STATE:
		ret = ablspi_do_get_state(adev, arg);
		break;
	case ABLSPI_CAN_SEND:
		ret = ablspi_do_can_send(adev);
		break;
	case ABLSPI_SET_MESSAGE_SIZE:
		ret = ablspi_do_set_message_size(adev, arg);
		break;
	case ABLSPI_GET_MESSAGE_SIZE:
		ret = ablspi_do_get_message_size(adev, arg);
		break;
	case ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE:
		ret = ablspi_do_wait_and_send_sized(adev, arg);
		break;
	case ABLSPI_SET_SPEED:
		ret = ablspi_do_set_speed(adev, arg);
		break;
	case ABLSPI_GET_SPEED:
		ret = ablspi_do_get_speed(adev, arg);
		break;
	default:
		ret = -ENOTTY;
		break;
	}

	mutex_unlock(&adev->lock);
	return ret;
}

static const struct file_operations ablspi_fops = {
	.owner		= THIS_MODULE,
	.open		= ablspi_open,
	.release	= ablspi_release,
	.read		= ablspi_read,
	.write		= ablspi_write,
	.mmap		= ablspi_mmap,
	.unlocked_ioctl	= ablspi_ioctl,
	.compat_ioctl	= compat_ptr_ioctl,
};

/* ---------- /proc/ableton/ablspi/<dev>/* ---------- */

static int ablspi_proc_show_irq_count(struct seq_file *s, void *unused)
{
	struct ablspi_dev *adev = s->private;

	seq_printf(s, "%u\n", (unsigned int)atomic_read(&adev->irq_count));
	return 0;
}

static int ablspi_proc_show_failed_send(struct seq_file *s, void *unused)
{
	struct ablspi_dev *adev = s->private;

	seq_printf(s, "%u\n",
		   (unsigned int)atomic_read(&adev->failed_send_count));
	return 0;
}

static int ablspi_proc_show_tx_time(struct seq_file *s, void *unused)
{
	struct ablspi_dev *adev = s->private;
	u64 last = atomic64_read(&adev->last_tx_ns);
	u64 total = atomic64_read(&adev->total_tx_ns);
	u64 max = atomic64_read(&adev->max_tx_ns);

	seq_printf(s, "last_ns %llu max_ns %llu total_ns %llu\n",
		   last, max, total);
	return 0;
}

static int ablspi_proc_open_irq_count(struct inode *inode, struct file *filp)
{
	return single_open(filp, ablspi_proc_show_irq_count, pde_data(inode));
}

static int ablspi_proc_open_failed_send(struct inode *inode, struct file *filp)
{
	return single_open(filp, ablspi_proc_show_failed_send, pde_data(inode));
}

static int ablspi_proc_open_tx_time(struct inode *inode, struct file *filp)
{
	return single_open(filp, ablspi_proc_show_tx_time, pde_data(inode));
}

static const struct proc_ops ablspi_proc_irq_count_ops = {
	.proc_open	= ablspi_proc_open_irq_count,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static const struct proc_ops ablspi_proc_failed_send_ops = {
	.proc_open	= ablspi_proc_open_failed_send,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static const struct proc_ops ablspi_proc_tx_time_ops = {
	.proc_open	= ablspi_proc_open_tx_time,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static int ablspi_proc_setup(struct ablspi_dev *adev)
{
	char name[32];

	snprintf(name, sizeof(name), "%d.%d", adev->bus_num, adev->chip_select);
	adev->proc_dev_dir = proc_mkdir(name, ablspi_proc_dir);
	if (!adev->proc_dev_dir)
		return -ENOMEM;

	if (!proc_create_data("irq_count", 0444, adev->proc_dev_dir,
			      &ablspi_proc_irq_count_ops, adev))
		goto err;
	if (!proc_create_data("failed_send_count", 0444, adev->proc_dev_dir,
			      &ablspi_proc_failed_send_ops, adev))
		goto err;
	if (!proc_create_data("spi_tx_time", 0444, adev->proc_dev_dir,
			      &ablspi_proc_tx_time_ops, adev))
		goto err;
	return 0;

err:
	proc_remove(adev->proc_dev_dir);
	adev->proc_dev_dir = NULL;
	return -ENOMEM;
}

static void ablspi_proc_teardown(struct ablspi_dev *adev)
{
	if (adev->proc_dev_dir) {
		proc_remove(adev->proc_dev_dir);
		adev->proc_dev_dir = NULL;
	}
}

/* ---------- GPIO IRQ setup ---------- */

static int ablspi_setup_gpio(struct ablspi_dev *adev)
{
	struct device *dev = &adev->spi->dev;
	int ret;

	/*
	 * Modern descriptor-based GPIO acquisition. The DT binding is
	 * `irq-gpios = <&gpio 3 GPIO_ACTIVE_HIGH>`. The legacy
	 * `irq-gpio = <3>` bare-integer form Ableton's stock driver used
	 * relies on a fixed gpiochip base of 0, which no longer holds on
	 * modern kernels (Armbian rpi-6.18.y bases gpiochip0 at 512).
	 * Using gpiod_get sidesteps the base entirely - we get a
	 * descriptor that resolves through the DT phandle.
	 *
	 * GPIOD_IN sets the line as input AND requests ownership in one
	 * call (replaces the old gpio_request + gpiod_direction_input
	 * sequence). devm_ variant auto-frees on driver detach.
	 */
	adev->irq_gpio = devm_gpiod_get(dev, "irq", GPIOD_IN);
	if (IS_ERR(adev->irq_gpio)) {
		ret = PTR_ERR(adev->irq_gpio);
		dev_err(dev, "could not get irq-gpios: %d\n", ret);
		adev->irq_gpio = NULL;
		return ret;
	}

	adev->irq = gpiod_to_irq(adev->irq_gpio);
	if (adev->irq < 0) {
		dev_err(dev, "gpiod_to_irq failed: %d\n", adev->irq);
		return adev->irq;
	}

	snprintf(adev->irq_name, sizeof(adev->irq_name), "ablspi-irq");

	/*
	 * Threaded IRQ with NULL primary so the entire wake path runs in a
	 * priority-tunable kernel thread. The Move's S23move init script
	 * relies on this: it does `chrt -p 91 \`pgrep ablspi\`` to pin the
	 * thread above audio-disturbing IRQs.
	 */
	ret = request_threaded_irq(adev->irq, NULL, ablspi_gpio_isr,
				   IRQF_TRIGGER_RISING | IRQF_ONESHOT,
				   adev->irq_name, adev);
	if (ret) {
		dev_err(dev, "request_irq failed with %d\n", ret);
		return ret;
	}

	adev->gpio_setup = true;
	return 0;
}

static void ablspi_teardown_gpio(struct ablspi_dev *adev)
{
	if (adev->gpio_setup) {
		free_irq(adev->irq, adev);
		adev->gpio_setup = false;
	}
	/* devm_gpiod_get auto-releases on device detach */
}

/* ---------- SPI driver probe/remove ---------- */

static int ablspi_probe(struct spi_device *spi)
{
	struct ablspi_dev *adev;
	struct page *page;
	int ret;

	if (!of_device_is_compatible(spi->dev.of_node, "ablspi"))
		return -ENODEV;

	adev = devm_kzalloc(&spi->dev, sizeof(*adev), GFP_KERNEL);
	if (!adev)
		return -ENOMEM;

	adev->spi	   = spi;
	adev->bus_num	   = spi->controller->bus_num;
	adev->chip_select  = spi_get_chipselect(spi, 0);
	adev->message_size = ABLSPI_DEFAULT_FRAME;
	adev->speed_hz	   = ABLSPI_DEFAULT_HZ;

	mutex_init(&adev->lock);
	init_completion(&adev->irq_event);
	init_completion(&adev->xfer_done);
	atomic_set(&adev->in_transfer, 0);
	atomic_set(&adev->open_count, 0);
	atomic_set(&adev->irq_count, 0);
	atomic_set(&adev->failed_send_count, 0);
	atomic64_set(&adev->last_tx_ns, 0);
	atomic64_set(&adev->total_tx_ns, 0);
	atomic64_set(&adev->max_tx_ns, 0);

	/*
	 * One page, page-aligned, suitable for remap_pfn_range and for the
	 * spi core's streaming DMA mapping.
	 */
	page = alloc_pages(GFP_KERNEL | __GFP_ZERO, 0);
	if (!page) {
		dev_err(&spi->dev, "open/ENOMEM\n");
		return -ENOMEM;
	}
	adev->buffer	 = page_address(page);
	adev->buffer_pfn = page_to_pfn(page);

	/* Configure SPI mode/word size/speed before exposing the chardev.
	 *
	 * SPI_MODE_3 (CPOL=1, CPHA=1) is REQUIRED — the XMOS firmware
	 * samples MOSI on the falling SCLK edge and drives MISO on the
	 * rising edge. Confirmed against stock ablspi.ko disassembly:
	 *
	 *   ablspi_probe+0x434:  orr  w2, w2, #0x3       ; mode |= 3
	 *   ablspi_probe+0x438:  str  w2, [x20, #848]    ; spi->mode
	 *   ablspi_probe+0x43c:  bl   spi_setup
	 *
	 * Defaulting to mode 0 produces consistent-but-misclocked traffic
	 * in both directions, which presents as "the XMOS replies look
	 * like valid USB-MIDI byte counts but every status byte is junk"
	 * and trips MoveLauncher's "Couldn't decode USB MIDI message"
	 * error. Took an embarrassingly long time to spot. */
	spi->mode |= SPI_MODE_3;
	spi->bits_per_word = 8;
	if (spi->max_speed_hz == 0 || spi->max_speed_hz > ABLSPI_MAX_HZ)
		spi->max_speed_hz = ABLSPI_DEFAULT_HZ;
	adev->speed_hz = spi->max_speed_hz;
	ret = spi_setup(spi);
	if (ret) {
		dev_err(&spi->dev, "Error registering ablspi spi driver: %d\n",
			ret);
		goto err_free_pages;
	}

	/* Allocate a minor and create the chardev. */
	adev->minor = ablspi_minor_alloc();
	if (adev->minor < 0) {
		dev_err(&spi->dev, "no minor number available!\n");
		ret = adev->minor;
		goto err_free_pages;
	}
	adev->devt = MKDEV(MAJOR(ablspi_devt_base), adev->minor);

	cdev_init(&adev->cdev, &ablspi_fops);
	adev->cdev.owner = THIS_MODULE;
	ret = cdev_add(&adev->cdev, adev->devt, 1);
	if (ret) {
		dev_err(&spi->dev,
			"Error %d adding ablspi character device\n", ret);
		goto err_free_minor;
	}

	adev->classdev = device_create(ablspi_class, &spi->dev, adev->devt,
				       adev, "ablspi%d.%d",
				       adev->bus_num, adev->chip_select);
	if (IS_ERR(adev->classdev)) {
		ret = PTR_ERR(adev->classdev);
		dev_err(&spi->dev, "device_create failed: %d\n", ret);
		goto err_cdev_del;
	}

	ret = ablspi_setup_gpio(adev);
	if (ret)
		goto err_device_destroy;

	ret = ablspi_proc_setup(adev);
	if (ret) {
		dev_warn(&spi->dev, "proc setup failed: %d\n", ret);
		/* /proc entries are non-fatal; continue. */
	}

	spi_set_drvdata(spi, adev);

	/*
	 * Pre-arm the IRQ-wake completion so the very first userspace
	 * WAIT_AND_SEND_MESSAGE_WITH_SIZE returns immediately and issues
	 * the initial SPI transfer.
	 *
	 * Empirically determined from a working stock Move: the XMOS
	 * doesn't fire its "frame ready" IRQ on power-up; it only fires
	 * AFTER receiving its first SPI frame from the host. Without this
	 * pre-arm, userspace deadlocks: it waits for an IRQ that requires
	 * a transfer that requires an IRQ. With it, the first ioctl skips
	 * the wait, does the kick-off transfer, and from then on the XMOS
	 * paces every subsequent frame via the IRQ as designed.
	 */
	complete(&adev->irq_event);

	dev_info(&spi->dev,
		 "ablspi%d.%d ready: irq=%d speed=%uHz frame=%u bytes\n",
		 adev->bus_num, adev->chip_select, adev->irq,
		 adev->speed_hz, adev->message_size);
	return 0;

err_device_destroy:
	device_destroy(ablspi_class, adev->devt);
err_cdev_del:
	cdev_del(&adev->cdev);
err_free_minor:
	ablspi_minor_free(adev->minor);
err_free_pages:
	free_pages((unsigned long)adev->buffer, 0);
	return ret;
}

static void ablspi_remove(struct spi_device *spi)
{
	struct ablspi_dev *adev = spi_get_drvdata(spi);

	if (!adev)
		return;

	ablspi_proc_teardown(adev);
	ablspi_teardown_gpio(adev);
	device_destroy(ablspi_class, adev->devt);
	cdev_del(&adev->cdev);
	ablspi_minor_free(adev->minor);
	if (adev->buffer)
		free_pages((unsigned long)adev->buffer, 0);
}

static const struct of_device_id ablspi_of_match[] = {
	{ .compatible = "ablspi" },
	{ },
};
MODULE_DEVICE_TABLE(of, ablspi_of_match);

static const struct spi_device_id ablspi_spi_ids[] = {
	{ "ablspi", 0 },
	{ },
};
MODULE_DEVICE_TABLE(spi, ablspi_spi_ids);

static struct spi_driver ablspi_spi_driver = {
	.driver = {
		.name		= ABLSPI_DRV_NAME,
		.of_match_table	= ablspi_of_match,
	},
	.id_table	= ablspi_spi_ids,
	.probe		= ablspi_probe,
	.remove		= ablspi_remove,
};

/* ---------- module init/exit ---------- */

static int __init ablspi_module_init(void)
{
	int ret;

	ret = alloc_chrdev_region(&ablspi_devt_base, 0, ABLSPI_MAX_DEVICES,
				  ABLSPI_DRV_NAME);
	if (ret)
		return ret;

	ablspi_class = class_create(ABLSPI_CLASS_NAME);
	if (IS_ERR(ablspi_class)) {
		ret = PTR_ERR(ablspi_class);
		pr_err("ablspi: Error adding ablspi_class: %d\n", ret);
		goto err_chrdev;
	}

	ablspi_proc_parent = proc_mkdir(ABLSPI_PROC_PARENT, NULL);
	if (!ablspi_proc_parent) {
		ret = -ENOMEM;
		goto err_class;
	}
	ablspi_proc_dir = proc_mkdir(ABLSPI_PROC_DIR, ablspi_proc_parent);
	if (!ablspi_proc_dir) {
		ret = -ENOMEM;
		goto err_proc_parent;
	}

	ret = spi_register_driver(&ablspi_spi_driver);
	if (ret) {
		pr_err("ablspi: Error registering ablspi spi driver: %d\n",
		       ret);
		goto err_proc_dir;
	}

	return 0;

err_proc_dir:
	proc_remove(ablspi_proc_dir);
err_proc_parent:
	proc_remove(ablspi_proc_parent);
err_class:
	class_destroy(ablspi_class);
err_chrdev:
	unregister_chrdev_region(ablspi_devt_base, ABLSPI_MAX_DEVICES);
	return ret;
}

static void __exit ablspi_module_exit(void)
{
	spi_unregister_driver(&ablspi_spi_driver);
	proc_remove(ablspi_proc_dir);
	proc_remove(ablspi_proc_parent);
	class_destroy(ablspi_class);
	unregister_chrdev_region(ablspi_devt_base, ABLSPI_MAX_DEVICES);
}

module_init(ablspi_module_init);
module_exit(ablspi_module_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("SPI driver for CM to XMOS communication (Ableton Move, CM5 port)");
MODULE_AUTHOR("Clean-room re-implementation, GPL-2.0-or-later");
MODULE_ALIAS("spi:ablspi");
