// SPDX-License-Identifier: GPL-2.0-only
/*
 * Bestechnic BES2600 BT UART driver
 *
 * Copyright (c) 2025 Dang Huynh <dang.huynh@mainlining.org>
 */

#include <linux/module.h>

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/types.h>
#include <linux/errno.h>
#include <linux/skbuff.h>

#include <linux/of.h>
#include <linux/of_irq.h>

#include <linux/device.h>
#include <linux/pm.h>
#include <linux/pm_wakeirq.h>

#include <linux/gpio/consumer.h>
#include <linux/pinctrl/consumer.h>
#include <linux/serdev.h>

#include <net/bluetooth/bluetooth.h>
#include <net/bluetooth/hci_core.h>

#include "bes2600.h"
#include "bes_chardev.h"

#include "h4_recv.h"

struct bes2600_btuart_data {
	struct serdev_device *serdev;
	struct hci_dev *hdev;

	struct pinctrl *pinctrl;
	struct pinctrl_state *pinctrl_default;

	/* Device tree properties */
	struct gpio_desc *power;
	struct gpio_desc *wakeup;
	int speed;

	unsigned long state;

	int wake_irq;
	bool opened;

	int err_count; /* workaround for broken firmware */

	struct sk_buff_head txq;
	struct work_struct tx_work;
	rwlock_t lock;

	struct sk_buff *rx_skb;
};

static const struct h4_recv_pkt bes2600_btuart_recv_pkts[] = {
	{ H4_RECV_ACL,      .recv = hci_recv_frame },
	{ H4_RECV_SCO,      .recv = hci_recv_frame },
	{ H4_RECV_EVENT,    .recv = hci_recv_frame },
};

static int bes2600_btuart_power(struct bes2600_btuart_data *data, bool enable)
{
	int ret, val;

	if (enable)
		val = 1;
	else
		val = 0;

	ret = gpiod_set_value_cansleep(data->power, val);
	if (ret)
		return ret;

	ret = bes2600_chrdev_switch_subsys_glb(-1, val);
	if (ret)
		return ret;

	return 0;
}

/*
 * HACK: Potential DOS issue, not sure if the firmware can filter it but
 * there needs to be a better way to detect this. Even better, fix the firmware.
 */
static int bes2600_btuart_bug_recovery(struct bes2600_btuart_data *data)
{
	struct hci_dev *hdev = data->hdev;
	struct serdev_device *serdev = data->serdev;

	bt_dev_info(hdev, "Attempting to recover from Firmware bug (might not work)");

	serdev_device_set_flow_control(serdev, false);
	bes2600_btuart_power(data, false);
	msleep(20);
	bes2600_btuart_power(data, true);
	serdev_device_set_flow_control(serdev, true);
	msleep(100);

	hci_reset_dev(hdev);

	return 0;
}

static int bes2600_btuart_recv(struct bes2600_btuart_data *data, const void *buffer, int count)
{
	struct hci_dev *hdev = data->hdev;
	int err = 0;

	data->rx_skb = h4_recv_buf(hdev, data->rx_skb, buffer, count,
				   bes2600_btuart_recv_pkts, ARRAY_SIZE(bes2600_btuart_recv_pkts));
	if (IS_ERR(data->rx_skb))
		err = PTR_ERR(data->rx_skb);

	return err;
}

static size_t bes2600_btuart_receive_buf(struct serdev_device *serdev,
					 const u8 *buf, size_t count)
{
	struct bes2600_btuart_data *data = serdev_device_get_drvdata(serdev);
	struct hci_dev *hdev = data->hdev;
	int ret;

	read_lock(&data->lock);
	ret = bes2600_btuart_recv(data, buf, count);
	if (ret) {
		bt_dev_err(hdev, "Failed to receive packet (%d)", ret);
		data->err_count++;
		ret = 0;
	} else {
		hdev->stat.byte_rx += count;
		ret = count;
	}
	read_unlock(&data->lock);

	/* Attempting to recovery from a bugged firmware */
	if (data->err_count > 10) {
		bes2600_btuart_bug_recovery(data);
		data->err_count = 0;
	}

	return ret;
}

static const struct serdev_device_ops bes2600_btuart_serdev_client_ops = {
	.receive_buf = bes2600_btuart_receive_buf,
	.write_wakeup = serdev_device_write_wakeup,
};

static void bes2600_btuart_wake(struct hci_dev *hdev, bool enable)
{
	struct bes2600_btuart_data *data = hci_get_drvdata(hdev);

	if (enable)
		gpiod_set_value_cansleep(data->wakeup, 1);
	else
		gpiod_set_value_cansleep(data->wakeup, 0);
}

static int bes2600_btuart_open(struct hci_dev *hdev)
{
	struct bes2600_btuart_data *data = hci_get_drvdata(hdev);
	struct serdev_device *serdev = data->serdev;
	int ret;

	ret = serdev_device_open(serdev);
	if (ret < 0) {
		bt_dev_err(hdev, "Failed to open serial device");
		return ret;
	}

	serdev_device_set_flow_control(serdev, false);

	ret = serdev_device_set_baudrate(serdev, data->speed);
	if (ret < 0) {
		bt_dev_err(hdev, "Failed to set baud rate");
		return ret;
	}

	serdev_device_set_flow_control(serdev, true);

	data->opened = true;

	bes2600_btuart_wake(hdev, true);
	return 0;
}

static int bes2600_btuart_flush(struct hci_dev *hdev)
{
	struct bes2600_btuart_data *data = hci_get_drvdata(hdev);
	struct serdev_device *serdev = data->serdev;

	serdev_device_write_flush(serdev);

	read_lock(&data->lock);
	skb_queue_purge(&data->txq);
	cancel_work_sync(&data->tx_work);
	read_unlock(&data->lock);

	return 0;
}

static int bes2600_btuart_close(struct hci_dev *hdev)
{
	struct bes2600_btuart_data *data = hci_get_drvdata(hdev);
	struct serdev_device *serdev = data->serdev;

	bes2600_btuart_wake(hdev, false);

	serdev_device_set_flow_control(serdev, false);
	serdev_device_close(serdev);

	data->opened = false;

	return 0;
}

static int bes2600_btuart_setup(struct hci_dev *hdev)
{
	struct bes2600_btuart_data *data = hci_get_drvdata(hdev);
	int ret;

	if (bes2600_chrdev_is_bus_error())
		return -EFAULT;

	/* Set pinctrl state to default */
	ret = pinctrl_select_state(data->pinctrl, data->pinctrl_default);
	if (ret < 0) {
		bt_dev_err(hdev, "Failed to setup pinctrl state");
		return ret;
	}

	/* Set power GPIO to high and tell chardev to switch to BT */
	bes2600_btuart_power(data, true);

	return 0;
}

static int bes2600_btuart_shutdown(struct hci_dev *hdev)
{
	struct bes2600_btuart_data *data = hci_get_drvdata(hdev);

	if (bes2600_chrdev_is_bus_error())
		return -EFAULT;

	bes2600_btuart_power(data, false);

	return 0;
}

static int bes2600_btuart_send_frame(struct hci_dev *hdev, struct sk_buff *skb)
{
	char *pkt_type = NULL;
	struct bes2600_btuart_data *data = hci_get_drvdata(hdev);

	switch (hci_skb_pkt_type(skb)) {
	case HCI_COMMAND_PKT:
		hdev->stat.cmd_tx++;
		break;
	case HCI_ACLDATA_PKT:
		hdev->stat.acl_tx++;
		break;
	case HCI_SCODATA_PKT:
		hdev->stat.sco_tx++;
		break;
	default:
		return -EILSEQ;
	}
	pkt_type = skb_push(skb, 1);
	pkt_type[0] = hci_skb_pkt_type(skb);
	read_lock(&data->lock);
	skb_queue_tail(&data->txq, skb);
	read_unlock(&data->lock);

	schedule_work(&data->tx_work);
	return 0;
}

static ssize_t bes2600_btuart_send(struct bes2600_btuart_data *data, struct sk_buff *skb)
{
	struct hci_dev *hdev = data->hdev;
	int len;

	len = serdev_device_write_buf(data->serdev, skb->data, skb->len);
	if (len < 0) {
		bt_dev_err(data->hdev, "Failed to write buffer to TTY");
		return -EIO;
	}
	serdev_device_wait_until_sent(data->serdev, 0);

	hdev->stat.byte_tx += len;

	skb_pull(skb, len);

	return skb->len;
}

static void bes2600_btuart_work(struct work_struct *work)
{
	struct bes2600_btuart_data *data = container_of(work, struct bes2600_btuart_data, tx_work);
	struct sk_buff *skb;

	while ((skb = skb_dequeue(&data->txq))) {
		if (bes2600_btuart_send(data, skb) > 0) {
			skb_queue_head(&data->txq, skb);
			break;
		}

		kfree_skb(skb);
	}
}

static void bes2600_btuart_parse_dt(struct serdev_device *serdev)
{
	struct bes2600_btuart_data *data = serdev_device_get_drvdata(serdev);
	struct device_node *node = serdev->dev.of_node;
	int speed = 1500000;

	of_property_read_u32(node, "current-speed", &speed);
	data->speed = speed;
}

static irqreturn_t bes2600_btuart_wakeup_handler(int irq, void *priv)
{
	struct bes2600_btuart_data *data = (struct bes2600_btuart_data *)priv;

	dev_info(&data->serdev->dev, "IRQ wake\n");

	return IRQ_HANDLED;
}

#ifdef CONFIG_PM_SLEEP
static int bes2600_btuart_suspend(struct device *dev)
{
	struct serdev_device *serdev = to_serdev_device(dev);
	struct bes2600_btuart_data *data = serdev_device_get_drvdata(serdev);

	if (data->opened) {
		bes2600_btuart_wake(data->hdev, false);

		if (device_may_wakeup(dev) && data->wake_irq)
			enable_irq_wake(data->wake_irq);
	}

	return 0;
}

static int bes2600_btuart_resume(struct device *dev)
{
	struct serdev_device *serdev = to_serdev_device(dev);
	struct bes2600_btuart_data *data = serdev_device_get_drvdata(serdev);

	if (data->opened) {
		bes2600_btuart_wake(data->hdev, true);

		if (device_may_wakeup(dev) && data->wake_irq)
			disable_irq_wake(data->wake_irq);
	}

	return 0;
}
#endif

static SIMPLE_DEV_PM_OPS(bes2600_btuart_pm_ops,
			bes2600_btuart_suspend, bes2600_btuart_resume);

static int bes2600_btuart_probe(struct serdev_device *serdev)
{
	struct device *dev = &serdev->dev;
	struct bes2600_btuart_data *data;
	struct hci_dev *hdev;
	int ret;

	data = devm_kzalloc(dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;

	skb_queue_head_init(&data->txq);

	data->pinctrl = devm_pinctrl_get(dev);
	if (IS_ERR(data->pinctrl))
		return dev_err_probe(dev, PTR_ERR(data->pinctrl), "Cannot get pinctrl\n");

	data->pinctrl_default = pinctrl_lookup_state(data->pinctrl, PINCTRL_STATE_DEFAULT);
	if (IS_ERR(data->pinctrl_default))
		return dev_err_probe(dev, PTR_ERR(data->pinctrl_default),
				"Cannot get default pinctrl state\n");

	data->power = devm_gpiod_get_index(dev, "power", 0, GPIOD_OUT_HIGH);
	if (IS_ERR(data->power))
		return dev_err_probe(dev, PTR_ERR(data->power), "Failed to get power gpio\n");

	data->wakeup = devm_gpiod_get_index_optional(dev, "wakeup", 0, GPIOD_OUT_HIGH);
	if (!data->wakeup)
		dev_err(dev, "Failed to get wakeup gpio\n");

	data->wake_irq = of_irq_get_byname(dev->of_node, "wakeup");
	if (data->wake_irq <= 0) {
		ret = data->wake_irq;
		dev_err(dev, "Failed to get IRQ number, host will not wake up (ret=%d)\n", ret);
	}

	if (data->wake_irq > 0) {
		ret = devm_device_init_wakeup(dev);
		if (ret)
			return dev_err_probe(dev, ret, "Failed to initialize device wakeup\n");

		ret = devm_request_threaded_irq(dev, data->wake_irq, NULL,
						bes2600_btuart_wakeup_handler,
						IRQF_ONESHOT | IRQF_TRIGGER_HIGH,
						"bes2600_btwakeup_irq", data);
		if (ret < 0)
			return dev_err_probe(dev, ret, "Cannot request IRQ\n");

		ret = devm_pm_set_wake_irq(dev, data->wake_irq);
		if (ret < 0)
			return dev_err_probe(dev, ret, "Failed to set wake irq\n");
	}

	data->err_count = 0;

	hdev = hci_alloc_dev();
	if (!hdev)
		return -ENOMEM;

	rwlock_init(&data->lock);

	data->serdev = serdev;
	data->hdev = hdev;

	serdev_device_set_drvdata(serdev, data);
	serdev_device_set_client_ops(serdev, &bes2600_btuart_serdev_client_ops);

	bes2600_btuart_parse_dt(serdev);

	INIT_WORK(&data->tx_work, bes2600_btuart_work);

	hdev->bus = HCI_UART;
	hci_set_drvdata(hdev, data);

	hdev->open = bes2600_btuart_open;
	hdev->close = bes2600_btuart_close;
	hdev->flush = bes2600_btuart_flush;
	hdev->setup = bes2600_btuart_setup;
	hdev->shutdown = bes2600_btuart_shutdown;
	hdev->send = bes2600_btuart_send_frame;
	hdev->manufacturer = 0x02B0;

	SET_HCIDEV_DEV(hdev, &serdev->dev);

	hci_set_quirk(hdev, HCI_QUIRK_BROKEN_STORED_LINK_KEY);

	/* Firmware claims to support HCI_OP_LE_READ_BUFFER_SIZE_V2 but broken */
	hci_set_quirk(hdev, HCI_QUIRK_BROKEN_BUFFER_SIZE_V2);

	/*
	 * Once shutdown() is ran, it turns off the Bluetooth regulator and
	 * would not power back on unless setup() is run again.
	 */
	hci_set_quirk(hdev, HCI_QUIRK_NON_PERSISTENT_SETUP);

	ret = hci_register_dev(hdev);
	if (ret < 0) {
		hci_free_dev(hdev);
		return dev_err_probe(dev, ret, "Failed to register HCI device\n");
	}

	return 0;
}

static void bes2600_btuart_remove(struct serdev_device *serdev)
{
	struct bes2600_btuart_data *data = serdev_device_get_drvdata(serdev);
	struct hci_dev *hdev = data->hdev;

	cancel_work_sync(&data->tx_work);
	if (hdev) {
		hci_unregister_dev(hdev);
		hci_free_dev(hdev);
	}
}

static const struct of_device_id bes2600_btuart_of_match[] = {
	{ .compatible = "bestechnic,bes2600-btuart", },
	{},
};
MODULE_DEVICE_TABLE(of, bes2600_btuart_of_match);

static struct serdev_device_driver bes2600_btuart_driver = {
	.probe = bes2600_btuart_probe,
	.remove = bes2600_btuart_remove,
	.driver = {
		.name = "bes2600_btuart",
		.pm = &bes2600_btuart_pm_ops,
		.of_match_table = of_match_ptr(bes2600_btuart_of_match),
	},
};
module_serdev_device_driver(bes2600_btuart_driver);

MODULE_AUTHOR("Dang Huynh <dang.huynh@mainlining.org>");
MODULE_DESCRIPTION("BES2600 BT UART driver");
MODULE_LICENSE("GPL");
