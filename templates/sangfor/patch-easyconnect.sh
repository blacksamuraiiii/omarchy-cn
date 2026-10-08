#!/bin/bash
# ==============================================================================
# patch-easyconnect.sh: 深信服 EasyConnect 凭据持久化、自动登录与服务死锁熔断补丁工具
#
# 功能特性：
# 1. 自动解包 /usr/share/sangfor/EasyConnect/resources/app.asar
# 2. 注入针对 SPA 路由时延双向状态机与 Loading 遮罩熔断保护的 preload.js 补丁 (V7.1)
# 3. 自动生成标准 RC4 加密的 setting_<user>.json 并持久化注入 savePwd=1 与 autoLogin=1
# 4. 固化 /etc/tmpfiles.d/easyconnect.conf 开机权限守护与 EasyMonitor.service 开机自启
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8 || tr -dc 'a-f0-9' < /dev/urandom | head -c 8)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][${TRACE_ID}][INFO] $1"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][${TRACE_ID}][WARN] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')][${TRACE_ID}][ERROR] $1"
    exit 1
}

# 默认凭据与配置（可通过环境变量注入覆盖，严禁硬编码敏感信息）
VPN_HOST="${VPN_HOST:-vpn.example.com:4430}"
VPN_USER="${VPN_USER:-username}"
VPN_PASS="${VPN_PASS:-password}"
CURRENT_USER="${SUDO_USER:-$USER}"

ASAR_FILE="/usr/share/sangfor/EasyConnect/resources/app.asar"
TMP_DIR="/tmp/ec_asar_patch_${TRACE_ID}"

log "=== 开始执行 EasyConnect 自动登录与防卡死固化补丁 ==="
log "目标网关: https://${VPN_HOST}"
log "登录账号: ${VPN_USER}"
log "宿主用户: ${CURRENT_USER}"

# 1. 环境校验
if [ ! -f "$ASAR_FILE" ]; then
    error "未找到 EasyConnect asar 资源文件: $ASAR_FILE"
fi

if ! command -v npx >/dev/null 2>&1; then
    error "系统未安装 npx，无法打包/解包 asar 归档，请先安装 Node.js"
fi

# 2. 备份原包
if [ ! -f "${ASAR_FILE}.orig" ]; then
    log "首次打补丁，创建原始备份: ${ASAR_FILE}.orig"
    sudo cp -p "$ASAR_FILE" "${ASAR_FILE}.orig"
fi

# 3. 解包 asar
log "正在解包 app.asar 至临时目录: $TMP_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
npx --yes asar extract "$ASAR_FILE" "$TMP_DIR/app"

PRELOAD_FILE="$TMP_DIR/app/src/service/preload.js"
if [ ! -f "$PRELOAD_FILE" ]; then
    error "解包异常，未在 asar 中找到 src/service/preload.js"
fi

# 4. 注入加固补丁 (清洗旧补丁并写入最新 V7.1 熔断补丁)
log "正在向 preload.js 注入自动连接、双向状态机与 Loading 熔断补丁..."
sed -i '/\/\/ === \[EC-AutoLogin/,$d' "$PRELOAD_FILE"

cat << 'EOF' >> "$PRELOAD_FILE"

// === [EC-AutoLogin-V7.1] EasyConnect 自动登录与资源加载状态加固补丁 ===
(function() {
    try {
EOF

cat << EOF >> "$PRELOAD_FILE"
        var VPN_HOST = "${VPN_HOST}";
        var TARGET_URL = "https://" + VPN_HOST;
        var USERNAME = "${VPN_USER}";
        var PASSWORD = "${VPN_PASS}";
EOF

cat << 'EOF' >> "$PRELOAD_FILE"
        // 场景 1：连接地址选择窗口 (connect.html)
        if (location.href.indexOf('connect.html') !== -1) {
            var connectChecks = 0;
            var connectTimer = setInterval(function() {
                connectChecks++;
                if (connectChecks > 50) { clearInterval(connectTimer); return; }
                var vm = window.avalon && window.avalon.vmodels && window.avalon.vmodels.connect;
                var input = document.getElementById('connAddrInput');
                if (vm && input) {
                    if (vm.connControl) { clearInterval(connectTimer); return; }
                    if (!vm.address || vm.address !== TARGET_URL) {
                        vm.address = TARGET_URL; input.value = TARGET_URL;
                    }
                    if (vm.errorValue) { vm.errorValue = ""; }
                    if (connectChecks >= 6 && !vm.connControl) {
                        clearInterval(connectTimer);
                        if (typeof vm.onSubmit === 'function') {
                            input.dispatchEvent(new Event('change', { bubbles: true }));
                            vm.onSubmit();
                        }
                    }
                }
            }, 200);
        }

        // 场景 2：网关用户认证窗口 (password 路由)
        if (location.href.indexOf(VPN_HOST) !== -1 && location.href.indexOf('shortcut.html') === -1) {
            var loginAttempts = 0;
            var maxWait = 200;
            var hasSubmitted = false;
            var filled = false;
            var submitWait = 0;

            var loginTimer = setInterval(function() {
                loginAttempts++;
                if (loginAttempts > maxWait) { clearInterval(loginTimer); return; }

                if (location.hash.indexOf('service') !== -1 || 
                    location.href.indexOf('service') !== -1 || 
                    location.hash.indexOf('logout') !== -1) {
                    clearInterval(loginTimer); return;
                }

                var vm = window.avalon && window.avalon.vmodels && window.avalon.vmodels.password;
                var usrInput = document.querySelector('.auto-input-usr input') ||
                               document.querySelector('input[name=username]') ||
                               document.querySelector('#username');
                var pwdInput = document.querySelector('.auto-input-pwd input') ||
                               document.querySelector('input[name=password]') ||
                               document.querySelector('#password');
                var submitBtn = document.querySelector('.auto-click-login button') || 
                                document.querySelector('.auto-click-login') ||
                                document.querySelector('button[type=submit]') ||
                                Array.from(document.querySelectorAll('button, a.btn')).find(function(b) {
                                    return /登|Log/i.test(b.innerText || b.textContent || b.value || "");
                                });

                if (loginAttempts % 10 === 1) {
                    console.log("[EC-V7.1] attempt=" + loginAttempts + 
                                " vm=" + (!!vm) + 
                                " loading=" + (vm ? vm.loading : 'N/A') + 
                                " usr=" + (!!usrInput) + 
                                " pwd=" + (!!pwdInput) + 
                                " pwdLen=" + (vm && vm.password ? vm.password.length : 0));
                }

                // 若 vm 正在加载中/登录中，说明正在请求认证，不打扰原生流程
                if (vm && vm.loading) {
                    return;
                }

                // 必须等到 avalon 视图模型和真实输入框均已就绪（排查 hidden-box 防填充干扰）
                if (!vm || !usrInput || !pwdInput) {
                    return;
                }

                // 遇证书/网络阻断等不可逆错误退出，避免死循环
                if (vm.errorData && 
                    vm.errorData.indexOf('username') === -1 && 
                    vm.errorData.indexOf('用户名') === -1 && 
                    vm.errorData.indexOf('password') === -1 && 
                    vm.errorData.indexOf('密码') === -1 &&
                    vm.errorData.indexOf('incorrect') === -1) {
                    console.log("[EC-V7.1] 遇到非凭据致命错误，退出自动登录:", vm.errorData);
                    clearInterval(loginTimer); return;
                }

                if (!filled) {
                    vm.username = USERNAME;
                    usrInput.value = USERNAME;
                    usrInput.dispatchEvent(new Event('input', { bubbles: true }));
                    usrInput.dispatchEvent(new Event('change', { bubbles: true }));

                    vm.password = PASSWORD;
                    pwdInput.value = PASSWORD;
                    pwdInput.dispatchEvent(new Event('input', { bubbles: true }));
                    pwdInput.dispatchEvent(new Event('change', { bubbles: true }));

                    if (vm.errorData) { vm.errorData = ""; }
                    filled = true;
                    console.log("[EC-V7.1] 凭据已注入 vm 与 DOM 节点");
                } else {
                    submitWait++;
                    if (submitWait >= 2 && !hasSubmitted) {
                        hasSubmitted = true;
                        clearInterval(loginTimer);
                        console.log("[EC-V7.1] 触发认证提交操作...");
                        setTimeout(function() {
                            if (submitBtn) {
                                console.log("[EC-V7.1] 点击登录按钮");
                                submitBtn.click();
                            } else if (typeof vm.login === 'function') {
                                console.log("[EC-V7.1] 调用 vm.login()");
                                vm.login();
                            } else {
                                console.log("[EC-V7.1] 回车提交");
                                pwdInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
                                pwdInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
                            }
                        }, 200);
                    }
                }
            }, 200);
        }

        // 场景 3：服务加载与 Loading 状态熔断保护
        if (location.href.indexOf(VPN_HOST) !== -1) {
            var serviceCheckCount = 0;
            var serviceTimer = setInterval(function() {
                serviceCheckCount++;
                if (serviceCheckCount > 60) { clearInterval(serviceTimer); return; }
                var loadingVm = window.avalon && window.avalon.vmodels && window.avalon.vmodels.common_loading;
                var serviceVm = window.avalon && window.avalon.vmodels && window.avalon.vmodels.service;
                var isServiceRoute = (location.hash.indexOf('service') !== -1) || !!serviceVm;

                if (isServiceRoute) {
                    if (loadingVm && loadingVm.toggle) { loadingVm.toggle = false; }
                    if (window.$eventManager && typeof window.$eventManager.$fire === 'function') {
                        window.$eventManager.$fire('all!onHideLoading', true);
                        window.$eventManager.$fire('all!onServiceInitLoadingClose', true);
                    }
                    if (serviceVm && !serviceVm.rsInit) { serviceVm.rsInit = true; }
                    clearInterval(serviceTimer);
                }
            }, 500);
        }
    } catch (e) {
        console.error("[EC-AutoLogin-V7.1] 运行异常:", e);
    }
})();
EOF

# 5. 重新打包 asar
log "正在重新打包 app.asar..."
npx --yes asar pack "$TMP_DIR/app" "$TMP_DIR/app.asar"
sudo cp "$TMP_DIR/app.asar" "$ASAR_FILE"
sudo cp -p "$TMP_DIR/app.asar" "${ASAR_FILE}.autologin_working"
sudo chmod 644 "$ASAR_FILE" "${ASAR_FILE}.autologin_working"
rm -rf "$TMP_DIR"

# 6. 配置持久化 JSON 生成 (优先采用客户端内置 Electron 进行 100% 兼容加密)
log "正在配置凭据持久化文件 setting_${CURRENT_USER}.json..."
CONF_DIR="/usr/share/sangfor/EasyConnect/resources/conf"
sudo mkdir -p "$CONF_DIR"

RUNNER="node"
if [ -x "/usr/share/sangfor/EasyConnect/EasyConnect" ]; then
    RUNNER="ELECTRON_RUN_AS_NODE=1 /usr/share/sangfor/EasyConnect/EasyConnect"
fi

$RUNNER -e "
const fs = require('fs');
const crypto = require('crypto');

const host = '${VPN_HOST}';
const user = '${VPN_USER}';
const pass = '${VPN_PASS}';
const salt = '__user_psw_salt_for_local_conf__';
const rc4Key = 'sangfor_cn';

let enc = '';
if (crypto.createCipher) {
    const cipher = crypto.createCipher('rc4', rc4Key);
    enc = cipher.update(salt + pass, 'utf8', 'hex') + cipher.final('hex');
} else {
    // 回退兼容现代 Node.js
    const md5 = crypto.createHash('md5').update(rc4Key).digest();
    const cipher = crypto.createCipheriv('rc4', md5, '');
    enc = cipher.update(salt + pass, 'utf8', 'hex') + cipher.final('hex');
}

const encUrl = encodeURIComponent('https://' + host);
const config = {
    global: {
        lang__sysconfig: 'en_US',
        version: '1',
        ecPort: '54530',
        lastVPNURL: JSON.stringify('https://' + host),
        vpnURLList: ['https://' + host],
        lang: JSON.stringify('en_US'),
        privacy__sysconfig: 1
    },
    vpn: {
        [encUrl]: {
            firstAuth: JSON.stringify('auth/psw'),
            lastTime: Date.now(),
            loginInfo: {
                password: enc,
                userName: user,
                savePwd: 1,
                autoLogin: 1
            }
        }
    }
};

const target = '${CONF_DIR}/setting_${CURRENT_USER}.json';
fs.writeFileSync(target, JSON.stringify(config, null, 4), 'utf8');
console.log('成功写入持久化配置: ' + target);
"

sudo chmod 666 "${CONF_DIR}/setting_${CURRENT_USER}.json"
sudo chown "${CURRENT_USER}:${CURRENT_USER}" "${CONF_DIR}/setting_${CURRENT_USER}.json"

# 7. 部署开机权限守护
if [ -f "${SCRIPT_DIR}/easyconnect.conf" ]; then
    log "正在安装 /etc/tmpfiles.d/easyconnect.conf 开机权限守护..."
    sudo cp "${SCRIPT_DIR}/easyconnect.conf" /etc/tmpfiles.d/easyconnect.conf
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/easyconnect.conf
fi

# 8. 确保 EasyMonitor.service 开机自启与运行
log "确保 EasyMonitor.service 处于 unmask 并已设置开机自启..."
sudo systemctl unmask EasyMonitor.service 2>/dev/null || true
sudo systemctl enable EasyMonitor.service 2>/dev/null || true
sudo systemctl restart EasyMonitor.service 2>/dev/null || true

log "=== EasyConnect 固化补丁部署完成！重启后点击桌面图标即可一键全自动连通 ==="
