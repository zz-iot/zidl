#ifndef UNION_ADMISSION_WIRE_H
#define UNION_ADMISSION_WIRE_H
#include <stdint.h>
#include <string.h>
typedef struct {size_t len;uint8_t bytes[256];} Record;
static void u32(uint8_t*p,uint32_t n,int le){for(unsigned i=0;i<4;i++)p[le?i:3-i]=(uint8_t)(n>>(8*i));}
static Record word(uint32_t id,uint32_t value,int le){Record r;memset(&r,0,sizeof r);r.len=8;u32(r.bytes,id|0x20000000u|(id==0?0x80000000u:0),le);u32(r.bytes+4,value,le);return r;}
static Record text(uint32_t id,int le){Record r;memset(&r,0,sizeof r);r.len=77;u32(r.bytes,id|0x40000000u,le);u32(r.bytes+4,69,le);u32(r.bytes+8,65,le);memset(r.bytes+12,'x',64);r.bytes[76]=0;return r;}
static Record unknown(int mu,int le){Record r;memset(&r,0,sizeof r);r.len=5;u32(r.bytes,50u|(mu?0x80000000u:0),le);r.bytes[4]=0x7e;return r;}
static size_t message(uint8_t*bytes,const Record*parts,size_t count,int le){memset(bytes,0,1024);bytes[1]=le?0x0b:0x0a;size_t n=8;for(size_t i=0;i<count;i++){n=(n+3)&~(size_t)3;memcpy(bytes+n,parts[i].bytes,parts[i].len);n+=parts[i].len;}u32(bytes+4,(uint32_t)(n-8),le);return n;}
static Record words(uint32_t id,int le){Record r;memset(&r,0,sizeof r);r.len=157;u32(r.bytes,id|0x40000000u,le);u32(r.bytes+4,149,le);u32(r.bytes+8,145,le);u32(r.bytes+12,2,le);u32(r.bytes+16,65,le);memset(r.bytes+20,'x',64);u32(r.bytes+88,65,le);memset(r.bytes+92,'x',64);return r;}
#endif
