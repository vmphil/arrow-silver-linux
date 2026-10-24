extern struct device *global_dev;

#ifdef CONFIG_BES2600_ENABLE_DEVEL_LOGS
#define bes_devel(fmt, ...) dev_debug(global_dev, fmt, ##__VA_ARGS__)
#else
#define bes_devel(fmt, ...) no_printk(fmt, ##__VA_ARGS__)
#endif
#define bes_info(fmt, ...) dev_info(global_dev, fmt, ##__VA_ARGS__)
#define bes_warn(fmt, ...) dev_warn(global_dev, fmt, ##__VA_ARGS__)
#define bes_err(fmt, ...) dev_err(global_dev, fmt, ##__VA_ARGS__)

/*
 * Legacy debug-subsystem-tagged log macros. The per-subsystem filtering
 * was never implemented in-tree; these shims let code paths gated by
 * CONFIG_BES2600_TESTMODE / CONFIG_BES2600_ITP / BES2600_DETECTION_LOGIC
 * build when their conditions are enabled. The first argument is
 * currently unused; pick one of the BES2600_DBG_* constants below for
 * documentation.
 */
#define BES2600_DBG_SBUS       0
#define BES2600_DBG_DOWNLOAD   0
#define BES2600_DBG_ITP        0
#define BES2600_DBG_TEST_MODE  0

#define bes2600_info(_dbg, fmt, ...) bes_info(fmt, ##__VA_ARGS__)
#define bes2600_err(_dbg, fmt, ...) bes_err(fmt, ##__VA_ARGS__)
#define bes2600_warn(_dbg, fmt, ...) bes_warn(fmt, ##__VA_ARGS__)
#define bes2600_dbg(_dbg, fmt, ...) bes_devel(fmt, ##__VA_ARGS__)
#define bes2600_err_with_cond(_cond, _dbg, fmt, ...)		\
	do {							\
		if (_cond)					\
			bes_err(fmt, ##__VA_ARGS__);		\
	} while (0)
