#!/usr/bin/env python3
"""Generate synthetic protocol fixtures. No camera dump or third-party preset is used."""
from pathlib import Path
import math, struct

ROOT=Path(__file__).resolve().parents[1]/'Tests/CoreTests'
BE=lambda n:struct.pack('>I',n)
LE16=lambda n:struct.pack('<H',n)

def encode(records):
    return b'NCP\0'+b''.join(BE(t)+BE(len(v))+v for t,v in records.items())+bytes(4)

def curve(points):
    header=bytes([0x49,0x30,0,255,0,255,1,0,len(points)])+bytes(v for p in points for v in p)
    header=header.ljust(64,b'\0')
    return header+b''.join(struct.pack('>H',round(i*32767/256)) for i in range(257))

def ncp(name,points,sharp=0,mono=False,state=2):
    body=b'0100'+name.encode().ljust(20,b'\0')
    body+=struct.pack('>H',0x064d if mono else 0x03c2)+bytes([state,255,128+sharp,1,1])
    body+=bytes([255,255,128,128,255]) if mono else bytes([128,128,255,255,255])
    assert len(body)==36
    return encode({1:body,2:curve(points)})

PARAMS={0x600:25,0x1600:26,0x700:27,0x800:28,0x900:29,0xA00:30,0xB00:31}

def np3(name,base=1,values=None,custom_curve=None):
    r={0x100:b'0300',0x200:name.encode().ljust(20,b'\0'),0x300:struct.pack('>H',base),0x400:bytes(2),0x500:bytes([255,1])}
    values=values or {}
    for tag,offset in PARAMS.items():r[tag]=bytes([(128+values.get(offset,0))%256,4])
    r.update({0xC00:bytes([255,0]),0xD00:bytes([255,0]),0xE00:bytes([255,4]),0xF00:bytes([255,1]),0x1000:bytes([255,1]),0x1100:bytes([255,1]),0x1200:bytes([255,1]),0x1300:bytes([255,1]),0x1400:bytes([128,1]),0x1500:bytes([255,10])})
    if custom_curve is not None:
        r[0x800]=r[0x900]=bytes([1,4]);r[2]=custom_curve
    return encode(dict(sorted(r.items())))

def payload(name,base=1,values=None,custom_curve=None,flag=0):
    p=bytearray(36);p[0]=base;p[2:22]=name.encode().ljust(20,b'\0');p[23]=flag
    for offset,value in (values or {}).items():p[offset]=value%256
    if custom_curve is not None:p[35]=1;p.extend(custom_curve)
    return p

def ptp_string(s):
    b=(s+'\0').encode('utf-16-le');return bytes([len(b)//2])+b

def array16(values):return struct.pack('<I',len(values))+b''.join(LE16(x) for x in values)

def main():
    ROOT.mkdir(parents=True,exist_ok=True)
    neutral_curve=curve([(0,0),(82,82),(255,255)])
    files={
        'neutral-curve.NCP':ncp('NEUTRAL-TEST',[(0,0),(82,82),(255,255)]),
        'neutral-state-zero.NCP':ncp('FIXTURE-COLOR',[(0,0),(38,38),(75,75),(176,176),(221,221),(255,255)],sharp=2,state=0),
        'mono-curve.NCP':ncp('FIXTURE-MONO',[(round(i*255/7),round(i*255/7)) for i in range(8)],sharp=3,mono=True,state=0),
        'neutral-export.NP3':np3('NEUTRAL-TEST',base=0x03c2,custom_curve=neutral_curve),
        'neutral-payload.bin':payload('NEUTRAL-TEST',base=2,custom_curve=neutral_curve),
        'standard.NP3':np3('STANDARD-02',values={25:12,26:8,27:4}),
        'standard.bin':payload('STANDARD-02',values={25:12,26:8,27:4},flag=1),
        'parameter-map.NP3':np3('Z30LAB-MAP',values={25:16,26:4,27:8,28:4,29:2,30:-4,31:1}),
        'parameter-map.bin':payload('Z30LAB-MAP',values={25:16,26:4,27:8,28:4,29:2,30:-4,31:1}),
        'current-picture-control.bin':payload('AUTO',base=8),
    }
    ops=[0x1001,0x1002,0x1003,0x1014,0x1015,0x1016,0x90C8,0x90CC,0x90CD,0x90CF]
    info=struct.pack('<HIH',100,10,100)+ptp_string('Synthetic Nikon PTP fixture')+LE16(0)
    for a in [ops,[],[0xD200],[],[]]:info+=array16(a)
    for s in ['Nikon','Z 30','V1.20','SYNTHETIC-TEST-ONLY']:info+=ptp_string(s)
    files['deviceinfo.bin']=info
    choices=list(range(1,9))+list(range(101,121))+list(range(201,210))
    files['photo-control-desc.bin']=LE16(0xD200)+LE16(4)+bytes([1])+LE16(8)+LE16(8)+bytes([2])+LE16(len(choices))+b''.join(map(LE16,choices))
    for name,data in files.items():(ROOT/name).write_bytes(data)
    print(f'Generated {len(files)} synthetic fixtures.')

if __name__=='__main__':main()
