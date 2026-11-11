# WGBar

แอป menu bar บน macOS สำหรับต่อ WireGuard ใช้ได้กับบัญชี Apple Developer แบบฟรี (ไม่ต้องใช้ Network Extension)

```
WGBar.app (SwiftUI, menu bar)  ──JSON / Unix socket──▶  wgbar-helper (root, LaunchDaemon)
                                 /var/run/wgbar.sock      ├─ wireguard-go  (สร้าง utun)
                                                          ├─ wg setconf    (key / peer)
                                                          ├─ ifconfig / route
                                                          └─ networksetup  (DNS)
```

## Requirements

- macOS 13 ขึ้นไป, Xcode 15 ขึ้นไป
- Homebrew และ:
  ```bash
  brew install wireguard-tools wireguard-go xcodegen
  ```
- user ต้องอยู่ในกลุ่ม **admin** (helper รับคำสั่งเฉพาะ admin)

## 1. ติดตั้ง helper

```bash
./scripts/install-helper.sh
```

สคริปต์จะ build, ติดตั้ง `/Library/PrivilegedHelperTools/wgbar-helper` และ `/usr/local/bin/wgbarctl`, โหลด LaunchDaemon แล้วทดสอบด้วย `wgbarctl ping` (สคริปต์จะถามรหัสผ่านเอง ห้ามรันด้วย sudo นำหน้า)

ตรวจสอบ:
```bash
wgbarctl doctor
```

## 2. ติดตั้งแอป

```bash
./scripts/build-app.sh
```
ได้ไฟล์ `build/WGBar-<version>.zip` ให้แตกไฟล์แล้วลาก `WGBar.app` ไปไว้ที่ `/Applications`

ถ้าจะ sign ด้วย Personal Team ให้ใส่ `DEVELOPMENT_TEAM` ใน `App/project.yml` ถ้าไม่ใส่จะ sign แบบ ad-hoc ซึ่งใช้งานได้ แต่ทุกครั้งที่ build ใหม่ Keychain จะถามสิทธิ์อีกรอบ

## 3. Import config

1. คลิกไอคอน ping บน menu bar แล้วเลือก **Import config…**
2. ลากไฟล์ `.conf` มาวาง (เช่นไฟล์ที่ export จาก OPNsense) แล้วตั้งชื่อ tunnel (a–z, 0–9, `_`, `-` ไม่เกิน 15 ตัว)
3. กด toggle ที่หัวเมนูเพื่อเชื่อมต่อ

ข้อควรรู้:
- config ทั้งไฟล์ (รวม private key) เก็บใน **Keychain** (`com.thanaboat.wgbar`) ส่วน UserDefaults เก็บแค่ชื่อและ endpoint
- ไม่รองรับ `PreUp/PostUp/PreDown/PostDown` และ config ที่มี key พวกนี้จะ import ไม่ได้ เพื่อกันการรันคำสั่งด้วยสิทธิ์ root
- **Route all traffic** ส่งทุก traffic ผ่าน tunnel (`0.0.0.0/0, ::/0`)
- ต่อได้ทีละ tunnel ถ้ากดเปลี่ยนไป tunnel อื่น ตัวเดิมจะปิดก่อน
- Quit แอปแล้ว tunnel ยังทำงานต่อ (ตั้งใจให้เป็นแบบนี้) เปิดแอปใหม่สถานะจะตรงกับของจริง

### ไอคอนบน menu bar

ไอคอนเป็นสัญญาณ sonar "ping"

| ไอคอน | สถานะ |
|---|---|
| วงกลางกลวง กับวงนอกเส้นประจาง | ไม่ได้เชื่อมต่อ |
| วงคลื่นขยายออกจากจุดกลาง | กำลังเชื่อมต่อ หรือกำลังตัดการเชื่อมต่อ |
| จุดกลางทึบ มีวงคลื่นนิ่ง 2 วง | เชื่อมต่ออยู่ |
| จุดกลางกลวง มีวงคลื่นนิ่ง | handshake หายไปนานเกิน 3 นาที |

## CLI

```bash
wgbarctl ping | status | refresh | doctor
```
```bash
wgbarctl up <name> <file.conf>
```
```bash
wgbarctl down <name>
```

## Troubleshooting

ดู log ของ helper แบบ realtime:
```bash
log stream --predicate 'subsystem == "com.thanaboat.wgbar"'
```
```bash
sudo tail -f /var/log/wgbar-helper.log
```

| อาการ | วิธีแก้ |
|---|---|
| แอปขึ้นแถบเหลือง "Helper not installed" | รัน `./scripts/install-helper.sh` |
| `wgbarctl doctor` ขึ้น FAIL ที่ helper responds | helper เป็นเวอร์ชันเก่า ให้รัน `install-helper.sh` ใหม่ |
| ไม่มี handshake | เช็ค endpoint, port forward และ firewall ฝั่ง server ลองทดสอบด้วย `sudo wg-quick up file.conf` เพื่อแยกว่าปัญหาอยู่ที่แอปหรือที่ config |
| DNS ไม่คืนค่าเดิม | helper เก็บค่าเดิมไว้ที่ `/Library/Application Support/WGBar/state/` และจะคืนให้เองตอน start รอบถัดไป |
| ใช้ `wg-quick` ทดสอบด้วยแล้วชนกัน | ต้อง `wg-quick down` ก่อนใช้ WGBar |

## Uninstall

ปิด tunnel ทุกตัวก่อน แล้วรัน:
```bash
./scripts/uninstall-helper.sh
```
จากนั้นลบ `WGBar.app` ทิ้ง และลบ item `com.thanaboat.wgbar` ใน Keychain Access ถ้าต้องการ

## Development

```bash
swift build && swift test
```
```bash
cd App && xcodegen generate && open WGBar.xcodeproj
```
```bash
swift scripts/make-icons.swift .
```
คำสั่งสุดท้ายใช้สร้าง App icon ใหม่
