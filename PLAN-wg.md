# WGBar — macOS WireGuard Client

> เอกสารนี้เป็นแผนงานสำหรับ Claude Code ให้ทำทีละ Phase ตามลำดับ
> ทุก Phase ต้องผ่านขั้น **Verify** ก่อนไป Phase ถัดไป ถ้า Verify ไม่ผ่านให้แก้ก่อน ห้ามข้าม

## 0. Context & Constraints

- เป้าหมาย: menu bar app บน macOS สำหรับต่อ WireGuard UI แบบ menu bar ที่ใช้งานง่าย
- **Apple Developer แบบฟรี** → ใช้ Network Extension (`packet-tunnel-provider`) ไม่ได้
- วิธีที่ใช้: **Menu bar app (user)** คุยกับ **Helper daemon (root, launchd)** ผ่าน Unix socket แล้ว helper เรียก `wireguard-go` กับ `wg`
- macOS 13+ (ใช้ `MenuBarExtra`), Swift 5.9+, Xcode 15+
- Peer หลักสำหรับทดสอบ: OPNsense WireGuard ที่บ้าน (และ EC2/OCI)
- ภาษาในโค้ด/คอมเมนต์: อังกฤษ ส่วนข้อความสรุปให้ผู้ใช้เขียนเป็นภาษาไทย

### Architecture

```
WGBar.app (SwiftUI, LSUIElement)
   │  JSON over Unix socket  /var/run/wgbar.sock (mode 0660, group = staff)
   ▼
wgbar-helper (root, LaunchDaemon com.thanaboat.wgbar.helper)
   ├─ wireguard-go utun     → สร้าง interface
   ├─ wg setconf <if> <file>→ ใส่ key/peer
   ├─ ifconfig / route      → ตั้ง Address, AllowedIPs
   ├─ networksetup          → ตั้ง DNS (และคืนค่าเดิมตอน down)
   └─ wg show <if> dump     → สถิติ
```

### Repo layout (สร้างตามนี้)

```
wgbar/
├── PLAN.md
├── README.md
├── Package.swift                 # SwiftPM: WGCore (lib), wgbar-helper (exe), wgbarctl (exe, debug CLI)
├── Sources/
│   ├── WGCore/                   # shared: config parser, IPC models, validation
│   │   ├── WGConfig.swift
│   │   ├── IPC.swift
│   │   └── Validation.swift
│   ├── wgbar-helper/
│   │   ├── main.swift            # socket server
│   │   ├── TunnelController.swift
│   │   ├── NetworkConfigurator.swift
│   │   └── Shell.swift           # exec with fixed argv, NO shell strings
│   └── wgbarctl/main.swift       # CLI client for testing
├── Tests/WGCoreTests/
├── App/                          # Xcode project: WGBar.app
│   ├── WGBar.xcodeproj           # generate with XcodeGen (project.yml)
│   ├── project.yml
│   └── WGBar/
│       ├── WGBarApp.swift
│       ├── TunnelStore.swift     # ObservableObject
│       ├── HelperClient.swift
│       ├── KeychainStore.swift
│       └── Views/
│           ├── MenuView.swift
│           ├── TunnelRow.swift
│           ├── PeerDetailView.swift
│           ├── ImportView.swift
│           └── SettingsView.swift
└── scripts/
    ├── install-helper.sh
    ├── uninstall-helper.sh
    └── com.thanaboat.wgbar.helper.plist
```

---

## Phase 1 — Prerequisites & manual sanity check

**Tasks**
1. ตรวจเครื่องมือ: `xcode-select -p`, `swift --version`, `brew --version`
2. ติดตั้ง: `brew install wireguard-tools wireguard-go xcodegen`
3. สร้าง `~/wg-test/home.conf` จาก config ที่ export มาจาก OPNsense (ให้ผู้ใช้ใส่เอง **ห้าม commit**)
4. ทดสอบด้วยมือ: `sudo wg-quick up ~/wg-test/home.conf`

**Verify**
- `sudo wg show` → มี `latest handshake` อยู่ภายในไม่กี่วินาที
- `ping <IP ภายในบ้าน เช่น athena>` ผ่าน
- `sudo wg-quick down ~/wg-test/home.conf` → interface หายไป, DNS คืนค่าเดิม (`scutil --dns`)

> ถ้า Phase นี้ไม่ผ่าน แปลว่าปัญหาอยู่ที่ config/server ไม่ใช่โค้ด ให้หยุดแล้วแจ้งผู้ใช้

---

## Phase 2 — Scaffold repo

**Tasks**
1. `git init`, สร้าง `.gitignore` (กัน `*.conf`, `.build/`, `DerivedData/`, `*.xcodeproj/xcuserdata`)
2. สร้าง `Package.swift` มี 3 targets + test target ตาม layout
3. สร้างไฟล์ว่างตาม layout ให้ build ผ่าน

**Verify**
- `swift build` ผ่าน
- `swift test` ผ่าน (มี test placeholder 1 ตัว)

---

## Phase 3 — WGCore: config parser + validation

**Tasks**
1. `WGConfig` parse ไฟล์ `.conf` มาตรฐาน:
   - `[Interface]`: PrivateKey, Address (หลายค่า, v4/v6), DNS (IP + search domain), MTU, ListenPort
   - `[Peer]` (หลายอัน): PublicKey, PresharedKey, Endpoint, AllowedIPs, PersistentKeepalive
   - ไม่ support PreUp/PostUp/PreDown/PostDown → **reject** (ป้องกันรันคำสั่ง root)
2. ฟังก์ชัน `wgSetconfText()` ให้ output เฉพาะ key ที่ `wg setconf` รับ (ตัด Address/DNS/MTU ออก)
3. `Validation`:
   - key = base64 32 bytes
   - CIDR valid
   - Endpoint = host:port
   - ชื่อ tunnel ใช้ได้แค่ `^[a-zA-Z0-9_-]{1,15}$`
4. `IPC.swift`: Codable models
   ```swift
   enum Request: Codable { case up(name: String, config: String), down(name: String), status, ping }
   struct Response: Codable { ok: Bool; error: String?; status: [TunnelStatus]? }
   struct TunnelStatus: Codable { name, interface: String; peers: [PeerStatus] }
   struct PeerStatus: Codable { publicKey, endpoint: String?; latestHandshake: Date?; rxBytes, txBytes: UInt64; allowedIPs: [String] }
   ```
   Framing: 4-byte big-endian length + JSON

**Verify**
- Unit tests: parse config ตัวอย่าง (ใช้ key ปลอม), config ที่ไม่มี DNS, หลาย peer, IPv6, reject PostUp, reject key ผิด, reject ชื่อ tunnel ผิด
- `swift test` ผ่านทั้งหมด

---

## Phase 4 — Helper daemon

**Tasks**
1. `Shell.swift`: ใช้ `Process` กับ `executableURL` + `arguments` ที่เป็น array **เท่านั้น** ห้าม `/bin/sh -c` และให้ resolve binary จาก allowlist path:
   `/opt/homebrew/bin/wireguard-go`, `/opt/homebrew/bin/wg`, `/usr/local/bin/...` (Intel), `/sbin/ifconfig`, `/sbin/route`, `/usr/sbin/networksetup`
2. `TunnelController.up(name, configText)`:
   1. validate ด้วย WGCore (validate ซ้ำฝั่ง helper เสมอ ไม่เชื่อ client)
   2. รัน `wireguard-go utun` โดยใช้ env `WG_TUN_NAME_FILE=/var/run/wireguard/<name>.name` เพื่ออ่านชื่อ utun ที่ได้
   3. เขียน setconf ลง temp file (0600, root) แล้วรัน `wg setconf <utun> <file>` จากนั้นลบไฟล์
   4. Address: `ifconfig <utun> inet <ip>/<mask> <ip> alias` (v6: `inet6 ... alias`), MTU: `ifconfig <utun> mtu <n>` (default 1420)
   5. Routes: ทุก AllowedIPs → `route -q -n add -inet <cidr> -interface <utun>`
      - ถ้ามี `0.0.0.0/0` ให้ใช้เทคนิค wg-quick: แยกเป็น `0.0.0.0/1` + `128.0.0.0/1` และเพิ่ม host route ของ endpoint ไปทาง default gateway เดิม (`route -n get default`)
   6. DNS: บันทึกค่าเดิมของทุก network service (`networksetup -listallnetworkservices`, `-getdnsservers`, `-getsearchdomains`) ลง `/var/run/wireguard/<name>.dns.json` แล้วค่อยตั้งค่าใหม่
   7. เก็บ state ใน memory + `/var/run/wireguard/<name>.state.json`
3. `TunnelController.down(name)`: คืนค่า DNS → ลบ routes → `rm /var/run/wireguard/<utun>.sock` (wireguard-go จะปิดเอง) → ลบ state
4. `status`: `wg show <utun> dump` แล้ว parse (tab-separated)
5. `main.swift`: socket server ที่ `/var/run/wgbar.sock`
   - `chown root:staff`, `chmod 0660`
   - ตรวจ peer credentials ด้วย `getpeereid` ว่า uid เป็นสมาชิก group `admin` (ถ้าไม่ใช่ให้ reject)
   - จำกัดขนาด request ไม่เกิน 64 KB
   - ตอน start ให้ cleanup state ที่ค้างจากรอบก่อน (กรณี crash)
   - Log ลง `os_log` subsystem `com.thanaboat.wgbar` **ห้าม log private key**
6. `wgbarctl`: `wgbarctl up <name> <file>`, `down <name>`, `status`, `ping`

**Verify**
- `swift build -c release`
- รันมือ: `sudo .build/release/wgbar-helper` แล้วเปิดอีก terminal:
  - `wgbarctl ping` → ok
  - `wgbarctl up home ~/wg-test/home.conf` → `wg show` มี handshake และ ping athena ได้
  - `wgbarctl status` → JSON มี rx/tx เพิ่มขึ้นเรื่อยๆ
  - `wgbarctl down home` → `ifconfig | grep utun` ไม่มี interface ของเรา และ `netstat -rn` ไม่มี route ค้าง, `scutil --dns` กลับเป็นค่าเดิม
- ทดสอบ full tunnel (AllowedIPs 0.0.0.0/0): `curl ifconfig.me` ได้ IP บ้าน/เซิร์ฟเวอร์ และหลัง down ได้ IP เดิม
- ทดสอบความปลอดภัย: ส่ง config ที่มี `PostUp = ...` → ถูก reject

---

## Phase 5 — Install as LaunchDaemon

**Tasks**
1. `com.thanaboat.wgbar.helper.plist`: `ProgramArguments=/Library/PrivilegedHelperTools/wgbar-helper`, `RunAtLoad`, `KeepAlive`, `StandardErrorPath=/var/log/wgbar-helper.log`
2. `install-helper.sh` (idempotent):
   ```bash
   swift build -c release
   sudo install -m 755 -o root -g wheel .build/release/wgbar-helper /Library/PrivilegedHelperTools/
   sudo install -m 644 -o root -g wheel scripts/com.thanaboat.wgbar.helper.plist /Library/LaunchDaemons/
   sudo launchctl bootout system/com.thanaboat.wgbar.helper 2>/dev/null || true
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.thanaboat.wgbar.helper.plist
   ```
3. `uninstall-helper.sh`: bootout แล้วลบไฟล์ทั้งหมด (ต้อง down tunnel ทั้งหมดก่อน)

**Verify**
- `sudo launchctl print system/com.thanaboat.wgbar.helper | grep state` → `running`
- `wgbarctl ping` ได้โดยไม่ต้อง sudo
- รีบูตเครื่องแล้ว `wgbarctl ping` ยังได้
- `sudo kill <pid>` → launchd restart เอง

---

## Phase 6 — Menu bar app (SwiftUI)

**Tasks**
1. `project.yml` (XcodeGen): target macOS app `WGBar`, deployment 13.0, `LSUIElement=YES`, link package `WGCore` (local path `..`), Signing: Personal Team (Automatic), **ปิด App Sandbox** (ต้องเข้าถึง `/var/run/wgbar.sock`)
2. `xcodegen generate` ใน `App/`
3. `HelperClient`: async/await, connect Unix socket, timeout 3s
4. `KeychainStore`: เก็บ config ทั้งไฟล์ (มี private key) ใน Keychain service `com.thanaboat.wgbar`, account = tunnel name ส่วน metadata (ชื่อ, ลำดับ, endpoint) เก็บใน `UserDefaults`
5. `TunnelStore` (`@MainActor ObservableObject`):
   - `tunnels: [TunnelProfile]`, `active: TunnelStatus?`, `helperReachable: Bool`
   - poll `status` ทุก 2 วินาทีตอนที่เมนูเปิด และทุก 10 วินาทีตอนปิด
   - `connect(name)` (ถ้ามี tunnel อื่นเปิดอยู่ให้ down ก่อน), `disconnect()`, `import(url)`, `delete(name)`
6. UI แบบ menu bar (`MenuBarExtra(style: .window)`, กว้าง ~320pt):
   - **Menu bar icon**: SF Symbol `network` (เทา) ตอน disconnected, `network.badge.shield.half.filled` ตอน connected (ใช้ template image)
   - **Header**: ชื่อแอป + `Toggle` ใหญ่ Connected/Disconnected + ชื่อ tunnel ที่ active
   - **Section "Tunnels"**: list ของ `TunnelRow` แสดงจุดสถานะ (เขียว/เทา), ชื่อ, endpoint และ hover ให้มีปุ่ม connect มีเครื่องหมายถูกที่อันที่ active
   - **Section "This device"** (ตอน connected): IP ใน tunnel (คลิกเพื่อ copy), handshake ล่าสุดแบบ relative ("12s ago" และเป็นสีเหลืองถ้าเกิน 3 นาที), ↓rx ↑tx แบบ human-readable
   - **Section "Route all traffic"**: toggle  สลับระหว่าง AllowedIPs เดิมกับ `0.0.0.0/0, ::/0` ซึ่งต้อง reconnect
   - **Footer**: Import config…, Settings…, Quit
   - ถ้า `helperReachable == false` ให้แสดง banner "Helper not installed" พร้อมคำแนะนำให้รัน `install-helper.sh`
7. `ImportView`: รับ drag & drop `.conf` / NSOpenPanel, validate ด้วย WGCore, ตั้งชื่อ tunnel
8. `SettingsView`: Launch at login (`SMAppService.mainApp`), แก้ config (TextEditor + validate), ลบ tunnel
9. ใช้ Notifications ตอน connect/disconnect/handshake หาย (ขอ permission)

**Verify**
- `xcodebuild -project App/WGBar.xcodeproj -scheme WGBar -configuration Debug build` ผ่าน
- เปิดแอป → มีไอคอนใน menu bar และไม่มีใน Dock
- Import `home.conf` → กด toggle → ไอคอนเปลี่ยน, handshake ขึ้น, rx/tx วิ่ง, ping athena ได้
- สลับไป tunnel อื่น → tunnel เดิม down ก่อน (`ifconfig` มี utun ของเราแค่อันเดียว)
- ปิด helper (`launchctl bootout`) → banner ขึ้นและแอปไม่ crash
- Quit แอปตอนต่ออยู่ → tunnel ยังอยู่ (เป็นพฤติกรรมที่ตั้งใจ) เปิดแอปใหม่แล้วสถานะต้องตรง
- ตรวจ Keychain Access → มี item `com.thanaboat.wgbar` และ `defaults read` ต้องไม่มี private key

---

## Phase 7 — Hardening & edge cases

**Tasks**
1. Sleep/wake: helper subscribe `NSWorkspace`/`IOKit` power notification หรือให้แอปส่ง `refresh` หลัง wake (re-resolve endpoint DNS ด้วย `wg set <if> peer <pk> endpoint <host:port>`)
2. Network change (Wi-Fi ↔ hotspot): ตรวจ default gateway ใหม่แล้วอัปเดต endpoint host route (กรณี full tunnel)
3. Handshake stale นานเกิน 3 นาที → แจ้งเตือนใน UI
4. ป้องกัน DNS leak ตอน full tunnel: ตั้ง DNS ให้ทุก network service ที่ active
5. ทำ `wgbarctl doctor`: เช็ค binary, socket, permission, utun ที่ค้าง

**Verify**
- ปิดฝา 5 นาทีแล้วเปิด → handshake กลับมาภายใน 30 วินาที
- สลับ Wi-Fi ไป hotspot มือถือ → ยังต่อได้
- https://dnsleaktest.com ตอน full tunnel ไม่เห็น DNS ของ ISP

---

## Phase 8 — Packaging & docs

**Tasks**
1. `scripts/build-app.sh`: `xcodebuild archive` → export `.app` (Development signing) → zip
2. `README.md` (ภาษาไทย): requirements, ติดตั้ง helper, ติดตั้งแอป, import config, troubleshooting (`log stream --predicate 'subsystem == "com.thanaboat.wgbar"'`), uninstall
3. Tag `v0.1.0`

**Verify**
- เครื่องสะอาด (หรือ user ใหม่): ทำตาม README แล้วต่อ tunnel ได้
- `uninstall-helper.sh` แล้วไม่มีไฟล์ค้างใน `/Library/PrivilegedHelperTools`, `/Library/LaunchDaemons`, `/var/run/wireguard`

---

## Rules for Claude Code

- ทำทีละ Phase แล้ว commit ทุก Phase (`feat(phaseN): ...`)
- คำสั่งที่ต้องใช้ `sudo` → **ให้หยุดแล้วบอกผู้ใช้ให้รันเอง** พร้อมแสดงคำสั่งให้ ห้ามพยายามใส่รหัสผ่าน
- ห้าม commit `.conf`, private key หรือ key จริงใน test (ใช้ `wg genkey` สร้าง key ทดสอบ)
- Helper ห้ามรัน shell string, ห้ามรับ path จาก client, ห้ามรองรับ Pre/PostUp
- ถ้า Verify ไม่ผ่าน 2 รอบ ให้สรุปอาการ + log แล้วถามผู้ใช้
- อนาคต (ไม่ต้องทำตอนนี้): เมื่อมีบัญชี Developer แบบเสียเงิน จะเปลี่ยน helper เป็น `NEPacketTunnelProvider` + WireGuardKit โดยใช้ UI เดิม
