#include "fixture.h"
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
typedef struct { int refs, limit, finalized; } Owner;
static int32_t retain(void *p) { Owner *o=p; assert(o->refs); if(o->refs==o->limit)return 1; ++o->refs; return 0; }
static void release(void *p) { Owner *o=p; assert(o->refs); if(!--o->refs)++o->finalized; }
static Probe_Value replacement;
static int report_after_replace;
static int32_t replace(void *p, Probe_Value *slot) { (void)p; int rc=Probe_Value_ref_assign(slot,replacement); return rc ? rc : report_after_replace; }
static int32_t get_value(void *p) { return *(int32_t *)p; }
int main(void) {
 Owner o={1,8,0}; int32_t values[]={11,22};
 struct Probe_Value_s a={&o,&values[0],retain,release,get_value,replace};
 struct Probe_Value_s b={&o,&values[1],retain,release,get_value,replace};
 Probe_Config cfg, copy;
 Probe_Config_init(&cfg); Probe_Config_init(&copy);
 assert(!cfg.group && !cfg.other);
 assert(!Probe_Config_set_group(&cfg,&a));
 assert(!Probe_Config_set_other(&cfg,&b));
 o.limit=4; /* first clone retain succeeds, second fails */
 assert(Probe_Config_clone(&copy,&cfg)==1);
 assert(!copy.group && !copy.other && o.refs==3);
 o.limit=8;
 assert(!Probe_Config_clone(&copy,&cfg) && o.refs==5);
 assert(Probe_Value_get_value(copy.other)==22);
 assert(!Probe_Config_set_group(&cfg,cfg.group));
 assert(!Probe_Config_set_other(&cfg,NULL) && o.refs==4);
 Probe_Config_fini(&cfg); Probe_Config_fini(&cfg);
 assert(o.refs==3);
 Probe_Config_fini(&copy); assert(o.refs==1);
 Probe_Value app=&a, config=NULL, member=NULL, callback=NULL;
 assert(!Probe_Value_ref_assign(&config,app));
 assert(!Probe_Value_ref_assign(&member,config));
 Probe_Value_ref_clear(&config); Probe_Value_ref_clear(&app);
 assert(o.refs==1 && Probe_Value_get_value(member)==11);
 replacement=&b;
 assert(!Probe_Value_replace(member,&callback));
 assert(callback==&b);
 assert(Probe_Value_get_value(callback)==22);
 o.limit=o.refs; Probe_Value failed=NULL;
 assert(Probe_Value_ref_assign(&failed,member)==1 && !failed);
 assert(!Probe_Value_ref_assign(&member,member));
 replacement=&a;
 assert(Probe_Value_replace(member,&callback)==1 && callback==&b);
 o.limit=8;
 assert(!Probe_Value_replace(member,&callback) && callback==&a);
 assert(Probe_Value_get_value(callback)==11);
 replacement=&b; report_after_replace=7;
 assert(Probe_Value_replace(member,&callback)==7 && callback==&b);
 assert(o.refs==2); /* bridge preserves provider output; it does not interpret status */
 Probe_Value_ref_clear(&member); assert(!o.finalized);
 Probe_Value_ref_clear(&callback); Probe_Value_ref_clear(&callback);
 assert(o.refs==0 && o.finalized==1);
 puts("PASS generated C/Zig: Config cloning and rollback, adjusted dispatch, inout and callback retirement");
}
