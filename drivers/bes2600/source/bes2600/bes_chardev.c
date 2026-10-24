/*
 * Mac80211 driver for BES2600 device
 *
 * Copyright (c) 2022, Bestechnic
 * Author:
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */
#include<linux/module.h>
#include <linux/init.h>
#include <linux/firmware.h>
#include <linux/etherdevice.h>
#include <linux/vmalloc.h>
#include <linux/random.h>
#include <linux/sched.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/atomic.h>
#include <linux/wait.h>
#include <linux/crc32.h>
#include <linux/version.h>
#include "bes2600.h"
#include "sbus.h"
#include "hwio.h"
#include "fwio.h"
#include "bes_chardev.h"
#include "tx_loop.h"
#include "bes_log.h"

enum wait_state {
	BES2600_BOOT_WAIT_NONE = 0,
	BES2600_BOOT_WAIT_PROBE_DONE,
	BES2600_BOOT_WAIT_CLOSE,
};

enum bus_probe_state {
	BES2600_BUS_PROBE_NONE = 0,
	BES2600_BUS_PROBE_START,
	BES2600_BUS_PROBE_OK,
	BES2600_BUS_PROBE_TIMEOUT,
};

struct bes_cdev {
	atomic_t num_proc;
	wait_queue_head_t open_wq;
	spinlock_t status_lock;
	bool wifi_opened;
	bool bt_opened;
	bool bton_pending;
	bool dpd_calied;
	u8 *dpd_data;
	u32 dpd_len;
	enum wait_state wait_state;
	wait_queue_head_t probe_done_wq;
	const struct sbus_ops *sbus_ops;
	struct sbus_priv *sbus_priv;
	bool sig_mode;
	int fw_type;
	bool bus_error;
	bool halt_dev;
	struct delayed_work probe_timeout_work;
	enum bus_probe_state bus_probe;
	struct work_struct wifi_force_close_work;
	enum pend_read_op read_flag;
	enum wakeup_event wakeup_by_event;	/* used to filter unwanted event wakeup reason report */
	u16 wakeup_state; /* for userspace check wakeup reason */
	wait_queue_head_t wakeup_reason_wq;
	u16 src_port;
#ifdef BES2600_DUMP_FW_DPD_LOG
	u8 *dpd_log;
	u16 dpd_log_len;
#endif
};

struct bes2600_op_map {
	char op[20];	// operation
	int op_len;	// operation length, used for effiency
	int (*handler)(const char *cmd); // handler
};

static struct bes_cdev bes2600_cdev;
module_param_named(fw_type, bes2600_cdev.fw_type, int, 0644);

extern int bes2600_register_net_dev(struct sbus_priv *bus_priv);
extern int bes2600_unregister_net_dev(struct sbus_priv *bus_priv);
extern bool bes2600_is_net_dev_created(struct sbus_priv *bus_priv);

static bool bes2600_bootup_end(void)
{
	bool end;

	spin_lock(&bes2600_cdev.status_lock);
	end = (bes2600_cdev.bus_probe == BES2600_BUS_PROBE_TIMEOUT ||
	       bes2600_cdev.sbus_priv != NULL ||
	       bes2600_cdev.bus_error);
	spin_unlock(&bes2600_cdev.status_lock);

	return end;
}

static int bes2600_chrdev_switch_subsys(int wake_flag, int subsys, bool active)
{
	int ret = 0;

	if (bes2600_cdev.sbus_priv == NULL)
		return -EFAULT;

	if (active) {
		if (bes2600_cdev.sbus_ops->gpio_wake)
			bes2600_cdev.sbus_ops->gpio_wake(bes2600_cdev.sbus_priv, wake_flag);

		if (bes2600_cdev.sbus_ops->sbus_active)
			ret = bes2600_cdev.sbus_ops->sbus_active(bes2600_cdev.sbus_priv, subsys);

		if (bes2600_cdev.sbus_ops->gpio_sleep)
			bes2600_cdev.sbus_ops->gpio_sleep(bes2600_cdev.sbus_priv, wake_flag);
	} else {
		if (bes2600_cdev.sbus_ops->gpio_wake)
			bes2600_cdev.sbus_ops->gpio_wake(bes2600_cdev.sbus_priv, wake_flag);

		if (bes2600_cdev.sbus_ops->sbus_deactive)
			ret = bes2600_cdev.sbus_ops->sbus_deactive(bes2600_cdev.sbus_priv, subsys);

		if (bes2600_cdev.sbus_ops->gpio_sleep)
			bes2600_cdev.sbus_ops->gpio_sleep(bes2600_cdev.sbus_priv, wake_flag);
	}

	return ret;
}

static int bes2600_switch_wifi(bool on)
{
	int ret = 0;
	long status = 0;

	if (bes2600_cdev.wifi_opened == on)
		return 0;

	if (on) {
		if (bes2600_chrdev_check_system_close()) {
			bes_devel("power up bes2600 when active wifi.\n");
			/* reset bus error status when restart bes2600 */
			spin_lock(&bes2600_cdev.status_lock);
			bes2600_cdev.bus_error = false;
			bes2600_cdev.halt_dev = false;
			bes2600_cdev.bus_probe = BES2600_BUS_PROBE_NONE;
			spin_unlock(&bes2600_cdev.status_lock);

			/* power up bes2600, trigger system to execute probe function */
			bes2600_cdev.wifi_opened = true;
			bes2600_cdev.sbus_ops->power_switch(NULL, 1);

			/* wait probe done event */
			status = wait_event_timeout(bes2600_cdev.probe_done_wq,
					bes2600_bootup_end(), HZ * 8);
			WARN_ON(status <= 0);
			ret = (status <= 0 || bes2600_chrdev_is_bus_error()) ? -1 : 0;
		} else {
			/* bes2600 is already powered up, we just need to create net device */
			if (bes2600_cdev.sbus_priv) {
				if (!bes2600_is_net_dev_created(bes2600_cdev.sbus_priv)) {
					ret = bes2600_register_net_dev(bes2600_cdev.sbus_priv);
				}
			} else {
				ret = -EFAULT;
			}
		}
	} else {
		if (bes2600_cdev.sbus_priv && bes2600_is_net_dev_created(bes2600_cdev.sbus_priv)) {
			bes2600_unregister_net_dev(bes2600_cdev.sbus_priv);
		}
	}

	if (!ret) {
		bes2600_cdev.wifi_opened = on;
	} else {
		bes2600_cdev.wifi_opened = false;
		if (on)
			bes_info("open wifi failed\n");
	}

	return ret;
}

static int bes2600_switch_bt(bool on)
{
	int ret = 0;
	long status = 0;

	if (bes2600_cdev.bt_opened == on)
		return 0;

	if (on) {
		if (bes2600_chrdev_check_system_close()) {
			bes_devel("power up bes2600 when active bt.\n");
			/* reset bus error status when restart bes2600 */
			spin_lock(&bes2600_cdev.status_lock);
			bes2600_cdev.bus_error = false;
			bes2600_cdev.halt_dev = false;
			bes2600_cdev.bus_probe = BES2600_BUS_PROBE_NONE;
			spin_unlock(&bes2600_cdev.status_lock);

			/* set opend state in advance */
			bes2600_cdev.bt_opened = true;
			bes2600_cdev.bton_pending = true;

			/* power up bes2600, trigger system to execute probe function */
			bes2600_cdev.sbus_ops->power_switch(NULL, 1);

			/* wait bootup process end */
			status = wait_event_timeout(bes2600_cdev.probe_done_wq,
				bes2600_bootup_end(), HZ * 8);
			WARN_ON(status <= 0);

			/* check if there is a error when bootup */
			ret = (status <= 0 || bes2600_chrdev_is_bus_error()) ? -1 : 0;
		} else {
			bes_devel("bes2600 activate bt.\n");
			ret = bes2600_chrdev_switch_subsys(GPIO_WAKE_FLAG_BT_ON, SUBSYSTEM_BT, true);
		}
	} else {
		bes_devel("bes2600 deactivate bt.\n");
		bes2600_chrdev_switch_subsys(GPIO_WAKE_FLAG_BT_OFF, SUBSYSTEM_BT, false);
	}

	if (!ret) {
		bes2600_cdev.bt_opened = on;
	} else {
		bes2600_cdev.bt_opened = false;
		bes2600_cdev.bton_pending = false;
		if (ret)
			bes_info("open bt failed\n");
	}

	return ret;
}

/*
 * This is a global function so we don't have to make many changes to
 * the driver.
 *
 * @wifi: 1 to turn on, 0 to turn off. Otherwise, leave unchanged
 * @bt: 1 to turn on, 0 to turn off. Otherwise, leave unchanged
 */
int bes2600_chrdev_switch_subsys_glb(int wifi, int bt)
{
	int ret = 0;

	switch (wifi) {
	case 0:
		ret = bes2600_switch_wifi(false);
		break;
	case 1:
		ret = bes2600_switch_wifi(true);
		break;
	default:
		break;
	}

	if (ret)
		goto result;

	switch (bt) {
	case 0:
		ret = bes2600_switch_bt(false);
		break;
	case 1:
		ret = bes2600_switch_bt(true);
		break;
	default:
		break;
	}

result:
	return ret;
}
EXPORT_SYMBOL_GPL(bes2600_chrdev_switch_subsys_glb);

static int bes2600_chrdev_check_system_close_internal(void)
{
	return (bes2600_cdev.sbus_ops->power_switch != NULL &&
		bes2600_cdev.fw_type == BES2600_FW_TYPE_WIFI_SIGNAL)
		&&(bes2600_cdev.bt_opened == false)
		&& (bes2600_cdev.wifi_opened == false);
}

const u8* bes2600_chrdev_get_dpd_data(u32 *len)
{
	if (!bes2600_cdev.dpd_calied)
		return NULL;
	if (len)
		*len = bes2600_cdev.dpd_len;

	return bes2600_cdev.dpd_data;
}

u8* bes2600_chrdev_get_dpd_buffer(u32 size)
{
	if (bes2600_cdev.dpd_data)
		kfree(bes2600_cdev.dpd_data);

	bes2600_cdev.dpd_data = kmalloc(size, GFP_KERNEL);
	if (!bes2600_cdev.dpd_data) {
		return NULL;
	}

	bes2600_cdev.dpd_len = DPD_BIN_SIZE;

	return bes2600_cdev.dpd_data;
}

void bes2600_chrdev_free_dpd_data(void)
{
	if (bes2600_cdev.dpd_data)
		kfree(bes2600_cdev.dpd_data);

	bes2600_cdev.dpd_data = NULL;
	bes2600_cdev.dpd_len = 0;
}

int bes2600_chrdev_update_dpd_data(void)
{
	u32 cal_crc = 0;
	u32 dpd_crc = le32_to_cpup((__le32 *)(bes2600_cdev.dpd_data));

	/* check if the dpd data is valid */
	cal_crc ^= 0xffffffffL;
	cal_crc = crc32_le(cal_crc, bes2600_cdev.dpd_data + 4, bes2600_cdev.dpd_len - 4);
	cal_crc ^= 0xffffffffL;
	if (cal_crc != dpd_crc) {
		bes_err(
			"bes2600 dpd data check failed, calc_crc:0x%08x dpd_crc: 0x%08x\n",
			cal_crc, dpd_crc);
		return -1;
	}

	bes_devel("bes2600 dpd cali pass.\n");

	/* update dpd calibration and wait state */
	spin_lock(&bes2600_cdev.status_lock);
	bes2600_cdev.dpd_calied = true;
	if (bes2600_chrdev_check_system_close_internal()) {
		bes2600_cdev.wait_state = BES2600_BOOT_WAIT_CLOSE;
	} else {
		bes2600_cdev.wait_state = BES2600_BOOT_WAIT_PROBE_DONE;
	}
	spin_unlock(&bes2600_cdev.status_lock);

	return 0;
}

#ifdef BES2600_DUMP_FW_DPD_LOG
void bes2600_free_dpd_log_buffer(void)
{
	if (bes2600_cdev.dpd_log)
		kfree(bes2600_cdev.dpd_log);

	bes2600_cdev.dpd_log_len = 0;
	bes2600_cdev.dpd_log = NULL;
}

u8* bes2600_alloc_dpd_log_buffer(u16 len)
{
	bes2600_cdev.dpd_log_len = len;

	if (bes2600_cdev.dpd_log)
		kfree(bes2600_cdev.dpd_log);

	bes2600_cdev.dpd_log = kzalloc(len, GFP_KERNEL);
	if (!bes2600_cdev.dpd_log) {
		bes2600_cdev.dpd_log_len = 0;
		return NULL;
	}

	return bes2600_cdev.dpd_log;
}

void bes2600_get_dpd_log(char **data, size_t *len)
{
	if (!bes2600_cdev.dpd_log) {
		*data = NULL;
		*len = 0;
	} else {
		*data = bes2600_cdev.dpd_log;
		*len = (size_t)bes2600_cdev.dpd_log_len;
	}
}
#endif /* BES2600_DUMP_FW_DPD_LOG */

void bes2600_chrdev_set_sbus_priv_data(struct sbus_priv *priv, bool error)
{
	bes2600_cdev.sbus_priv = priv;
	if (priv) {
		if (bes2600_cdev.bton_pending) {
			bes_devel("execute pending bt on operation.\n");
			bes2600_chrdev_switch_subsys(GPIO_WAKE_FLAG_BT_ON, SUBSYSTEM_BT, true);

			bes2600_cdev.bton_pending = false;
		}

		spin_lock(&bes2600_cdev.status_lock);
		if (bes2600_cdev.wait_state == BES2600_BOOT_WAIT_PROBE_DONE) {
			bes2600_cdev.wait_state = BES2600_BOOT_WAIT_NONE;
		}
		spin_unlock(&bes2600_cdev.status_lock);

		bes_devel("wakup proc on wq of probe_done.\n");
	} else {
		spin_lock(&bes2600_cdev.status_lock);
		bes2600_cdev.wait_state = BES2600_BOOT_WAIT_NONE;
		bes2600_cdev.bus_error = error;
		if (bes2600_cdev.bus_error) {
			bes2600_cdev.wifi_opened = false;
			bes2600_cdev.bt_opened = false;
			bes2600_cdev.bton_pending = false;
			bes2600_cdev.bus_probe = BES2600_BUS_PROBE_NONE;
		}
		spin_unlock(&bes2600_cdev.status_lock);
		bes_devel("wakup proc on wq of disconnect_done.\n");
	}

	wake_up(&bes2600_cdev.probe_done_wq);
}

struct sbus_priv * bes2600_chrdev_get_sbus_priv_data(void)
{
	return bes2600_cdev.sbus_priv;
}

int bes2600_chrdev_check_system_close(void)
{
	bool sys_closed = false;

	spin_lock(&bes2600_cdev.status_lock);
	sys_closed = bes2600_chrdev_check_system_close_internal();
	spin_unlock(&bes2600_cdev.status_lock);

	return sys_closed;
}

int bes2600_chrdev_do_system_close(const struct sbus_ops *sbus_ops, struct sbus_priv *priv)
{
	int ret = 0;
	long status = 0;

	if (!sbus_ops || !priv) {
		bes_warn("abort power down device.\n");
		return 0;
	}

	if (!sbus_ops->power_switch)
		return 0;

	bes_devel("power down bes2600.\n");

	/* trigger system to execute disconnect function */
	ret = sbus_ops->power_switch(priv, 0);

	/* wait disconnect event */
	status = wait_event_timeout(bes2600_cdev.probe_done_wq, (bes2600_cdev.sbus_priv == NULL), HZ * 3);
	WARN_ON(status <= 0);

	return ret;
}

bool bes2600_chrdev_is_wifi_opened(void)
{
	bool wifi_opened = false;

	spin_lock(&bes2600_cdev.status_lock);
	wifi_opened = bes2600_cdev.wifi_opened;
	spin_unlock(&bes2600_cdev.status_lock);

	if (bes2600_cdev.fw_type == BES2600_FW_TYPE_WIFI_NO_SIGNAL)
		return true;
	else if (bes2600_cdev.fw_type == BES2600_FW_TYPE_BT)
		return false;
	else if (bes2600_cdev.fw_type == BES2600_FW_TYPE_WIFI_SIGNAL)
		return wifi_opened;

	return false;
}

bool bes2600_chrdev_is_bt_opened(void)
{
	bool bt_opened = false;

	spin_lock(&bes2600_cdev.status_lock);
	bt_opened = bes2600_cdev.bt_opened;
	spin_unlock(&bes2600_cdev.status_lock);

	if (bes2600_cdev.fw_type == BES2600_FW_TYPE_WIFI_NO_SIGNAL)
		return false;
	else if (bes2600_cdev.fw_type == BES2600_FW_TYPE_BT)
		return true;
	else if (bes2600_cdev.fw_type == BES2600_FW_TYPE_WIFI_SIGNAL)
		return bt_opened;

	return false;
}

void bes2600_chrdev_wakeup_bt(void)
{
	int ret = 0;

	if (bes2600_cdev.bt_opened && bes2600_cdev.sbus_priv) {
		bes_devel("wakeup bt in resume flow\n");
		ret = bes2600_chrdev_switch_subsys(GPIO_WAKE_FLAG_BT_LP_ON, SUBSYSTEM_BT_LP, true);

		if (ret)
			bes_err("Wakeup BT fail in resume\n");
	}
}
EXPORT_SYMBOL_GPL(bes2600_chrdev_wakeup_bt);

int bes2600_chrdev_get_fw_type(void)
{
	return bes2600_cdev.fw_type;
}

bool bes2600_chrdev_is_signal_mode(void)
{
	return bes2600_cdev.sig_mode;
}

bool bes2600_chrdev_is_bus_error(void)
{
	bool error = false;

	spin_lock(&bes2600_cdev.status_lock);
	error = (bes2600_cdev.bus_error || bes2600_cdev.bus_probe != BES2600_BUS_PROBE_OK);
	spin_unlock(&bes2600_cdev.status_lock);

	return error;
}
EXPORT_SYMBOL_GPL(bes2600_chrdev_is_bus_error);

void bes2600_chrdev_update_signal_mode(void)
{
	if (bes2600_cdev.fw_type >= BES2600_FW_TYPE_MAX_NUM) {
		bes2600_cdev.fw_type = BES2600_FW_TYPE_WIFI_SIGNAL;
		bes_warn("unexpected fw type, switch to wifi signal mode\n");
	}

	if (bes2600_cdev.fw_type == BES2600_FW_TYPE_WIFI_SIGNAL) {
		bes2600_cdev.sig_mode = true;
	} else if ((bes2600_cdev.fw_type == BES2600_FW_TYPE_WIFI_NO_SIGNAL)
		|| (bes2600_cdev.fw_type == BES2600_FW_TYPE_BT)) {
		bes2600_cdev.sig_mode = false;
	}
}

static void bes2600_chrdev_wifi_force_close_work(struct work_struct *work)
{
	if (bes2600_chrdev_is_wifi_opened()) {
		bes_devel("system exeception, force wifi down\n");

		/* halt device if needed */
		if (bes2600_cdev.halt_dev && bes2600_cdev.sbus_ops->halt_device) {
			bes2600_cdev.sbus_ops->halt_device(bes2600_cdev.sbus_priv);
		}

		/* unregister wifi */
		bes2600_switch_wifi(0);

		/* power down device if wifi is only opened */
		if (bes2600_chrdev_check_system_close()) {
			bes2600_chrdev_do_system_close(bes2600_cdev.sbus_ops,
						bes2600_cdev.sbus_priv);
		}
	}
}

void bes2600_chrdev_wifi_force_close(struct bes2600_common *hw_priv, bool halt_dev)
{
	if (hw_priv == NULL)
		return;

	if (bes2600_chrdev_is_wifi_opened() &&
	   !work_pending(&bes2600_cdev.wifi_force_close_work)) {
		spin_lock(&bes2600_cdev.status_lock);
		bes2600_cdev.bus_error = true;
		bes2600_cdev.halt_dev = halt_dev;
		spin_unlock(&bes2600_cdev.status_lock);

		bes2600_tx_loop_set_enable(hw_priv, true);
		schedule_work(&bes2600_cdev.wifi_force_close_work);
	}
}

void bes2600_chrdev_usb_remove(struct bes2600_common *hw_priv)
{
	if (hw_priv == NULL)
		return;

	if (bes2600_chrdev_is_wifi_opened() &&
	   !work_pending(&bes2600_cdev.wifi_force_close_work)) {
		spin_lock(&bes2600_cdev.status_lock);
		bes2600_cdev.bus_error = true;
		spin_unlock(&bes2600_cdev.status_lock);

		bes2600_tx_loop_set_enable(hw_priv, false);
		bes2600_chrdev_wifi_force_close_work(&bes2600_cdev.wifi_force_close_work);
	}
}

static void bes2600_probe_timeout_work(struct work_struct *work)
{
	spin_lock(&bes2600_cdev.status_lock);
	bes2600_cdev.bus_probe = BES2600_BUS_PROBE_TIMEOUT;
	bes2600_cdev.wifi_opened = false;
	bes2600_cdev.bt_opened = false;
	bes2600_cdev.bton_pending = false;
	spin_unlock(&bes2600_cdev.status_lock);

	bes_devel("bus probe timeout\n");
	wake_up(&bes2600_cdev.probe_done_wq);
}

void bes2600_chrdev_start_bus_probe(void)
{
	spin_lock(&bes2600_cdev.status_lock);
	bes2600_cdev.bus_probe = BES2600_BUS_PROBE_START;
	spin_unlock(&bes2600_cdev.status_lock);

	cancel_delayed_work_sync(&bes2600_cdev.probe_timeout_work);
	schedule_delayed_work(&bes2600_cdev.probe_timeout_work, 3 * HZ);
}

void bes2600_chrdev_bus_probe_notify(void)
{
	spin_lock(&bes2600_cdev.status_lock);
	bes2600_cdev.bus_probe = BES2600_BUS_PROBE_OK;
	spin_unlock(&bes2600_cdev.status_lock);
	cancel_delayed_work_sync(&bes2600_cdev.probe_timeout_work);

	wake_up(&bes2600_cdev.probe_done_wq);
}

void bes2600_chrdev_wifi_update_wakeup_reason(u16 reason, u16 port)
{
	spin_lock(&bes2600_cdev.status_lock);
	bes2600_cdev.wakeup_state = reason;
	bes2600_cdev.src_port = port;
	spin_unlock(&bes2600_cdev.status_lock);
}

void bes2600_chrdev_wakeup_by_event_set(enum wakeup_event wakeup_event)
{
	spin_lock(&bes2600_cdev.status_lock);
	bes2600_cdev.wakeup_by_event = wakeup_event;
	spin_unlock(&bes2600_cdev.status_lock);
	if (wakeup_event == WAKEUP_EVENT_NONE)
		wake_up(&bes2600_cdev.wakeup_reason_wq);
}

int bes2600_chrdev_wakeup_by_event_get(void)
{
	return bes2600_cdev.wakeup_by_event;
}

int bes2600_chrdev_init(struct sbus_ops *ops)
{
	/* initialise global variable */
	atomic_set(&bes2600_cdev.num_proc, 0);
	init_waitqueue_head(&bes2600_cdev.open_wq);
	spin_lock_init(&bes2600_cdev.status_lock);
	init_waitqueue_head(&bes2600_cdev.probe_done_wq);
	INIT_WORK(&bes2600_cdev.wifi_force_close_work, bes2600_chrdev_wifi_force_close_work);
	INIT_DELAYED_WORK(&bes2600_cdev.probe_timeout_work, bes2600_probe_timeout_work);
	init_waitqueue_head(&bes2600_cdev.wakeup_reason_wq);
	bes2600_chrdev_wakeup_by_event_set(WAKEUP_EVENT_NONE);
#ifdef CONFIG_BES2600_WIFI_BOOT_ON
	bes2600_cdev.wifi_opened = true;
#else
	bes2600_cdev.wifi_opened = false;
#endif
#ifdef CONFIG_BES2600_BT_BOOT_ON
	bes2600_cdev.bt_opened = true;
	bes2600_cdev.bton_pending = true;
#else
	bes2600_cdev.bt_opened = false;
	bes2600_cdev.bton_pending = false;
#endif
	bes2600_cdev.dpd_calied = false;
	bes2600_cdev.wait_state = BES2600_BOOT_WAIT_NONE;
	bes2600_cdev.sbus_ops = ops;
	bes2600_cdev.bus_error = false;
	bes2600_cdev.halt_dev = false;
	bes2600_cdev.read_flag = BES_CDEV_READ_NUM_MAX;
	bes2600_cdev.wakeup_by_event = WAKEUP_EVENT_NONE;
	bes_devel("%s done\n", __func__);

	return 0;
}

void bes2600_chrdev_free(void)
{
	cancel_delayed_work_sync(&bes2600_cdev.probe_timeout_work);
#ifdef BES2600_DUMP_FW_DPD_LOG
	bes2600_free_dpd_log_buffer();
#endif
	bes2600_chrdev_free_dpd_data();
	bes_devel("%s done\n", __func__);
}
