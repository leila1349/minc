#ifndef _MINC_CONFIG_H_
#define _MINC_CONFIG_H_

#define MICFG_FORCE_V2 "MINC_FORCE_V2"
#define MICFG_COMPRESS "MINC_COMPRESS"
#define MICFG_CHUNKING "MINC_CHUNKING"
#define MICFG_LOGFILE  "MINC_LOGFILE"
#define MICFG_LOGLEVEL "MINC_LOGLEVEL"

extern int miget_cfg_bool(const char *);
extern int miget_cfg_int(const char *);
extern char * miget_cfg_str(const char *);

#endif /* _MINC_CONFIG_H_ */
