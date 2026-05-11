const translations = {
    en: {
        heroTitle: "Seamless Network Mounting",
        heroSubtitle: "The lightweight, menu-bar essential for macOS. Auto-mount network shares effortlessly.",
        downloadBtn: "Download for macOS",
        versionInfo: "v1.0.2 • macOS 14+",
        brewCmd: "brew tap jasine/tap && brew install --cask netmounter",
        feature1Title: "Auto-Mount",
        feature1Desc: "Automatically detects your network environment and mounts the right shares instantly.",
        feature7Title: "Network Discovery",
        feature7Desc: "Auto-discover servers and shares on your network via Bonjour/mDNS. Browse and add with one click.",
        feature2Title: "Multi-Protocol",
        feature2Desc: "Supports SMB, NFS, AFP, and WebDAV protocols for all your network storage needs.",
        feature3Title: "Secure & Native",
        feature3Desc: "Built with native Swift APIs. Passwords securely stored in macOS Keychain.",
        feature4Title: "Liquid Glass UI",
        feature4Desc: "A stunning, modern interface designed for macOS Sonoma and beyond.",
        feature5Title: "Launch at Login",
        feature5Desc: "Start automatically with your Mac. Always ready when you need it.",
        feature6Title: "Menu Bar App",
        feature6Desc: "Lives in your menu bar. One click to mount or unmount any server.",
        feature8Title: "VPN Awareness",
        feature8Desc: "Auto-detects VPN routing. Mounts when VPN connects, unmounts when it disconnects.",
        feature9Title: "Sleep/Wake Reconnect",
        feature9Desc: "Gracefully disconnects before sleep and auto-reconnects all mounts after wake.",
        feature10Title: "URL Scheme Sharing",
        feature10Desc: "Share server configs as netmounter:// links. One click to import for your whole team.",
        feature11Title: "Smart Notifications",
        feature11Desc: "Get notified on mount success, failure, and recovery. Retry failed mounts from the notification.",
        feature12Title: "Zombie Mount Healing",
        feature12Desc: "Automatically detects unresponsive mounts and recovers them without manual intervention.",
        protocolsTitle: "Supported Protocols",
        protocolSmb: "Windows & NAS file sharing",
        protocolNfs: "Linux & Unix file sharing",
        protocolAfp: "Apple file sharing (legacy)",
        protocolWebdav: "Nextcloud, ownCloud & more",
        comparisonTitle: "Why NetMounter?",
        comparisonFeature: "Feature",
        comparisonMenuBar: "Menu Bar App",
        comparisonAutoMount: "Auto-Mount by Network",
        comparisonDiscovery: "Network Discovery",
        comparisonMultiProtocol: "Multi-Protocol (SMB/NFS/AFP/WebDAV)",
        comparisonBrew: "Homebrew Install",
        comparisonFree: "Free & Open Source",
        comparisonModernUI: "Modern Liquid Glass UI",
        comparisonKeychain: "Keychain Integration",
        comparisonVPN: "VPN-Aware Auto-Mount",
        comparisonSleepWake: "Sleep/Wake Reconnect",
        comparisonURLScheme: "URL Scheme Sharing",
        comparisonNotifications: "Mount Notifications",
        comparisonLaunchLogin: "Launch at Login",
        footerRights: "All rights reserved."
    },
    zh: {
        heroTitle: "无感网络挂载体验",
        heroSubtitle: "专为 macOS 打造的轻量级菜单栏工具。自动挂载网络共享，从未如此轻松。",
        downloadBtn: "下载 macOS 版本",
        versionInfo: "v1.0.2 • macOS 14+",
        brewCmd: "brew tap jasine/tap && brew install --cask netmounter",
        feature1Title: "智能自动挂载",
        feature1Desc: "自动识别网络环境，即时挂载对应的网络共享，无缝衔接。",
        feature7Title: "网络发现",
        feature7Desc: "通过 Bonjour/mDNS 自动发现局域网服务器和共享目录，一键添加。",
        feature2Title: "多协议支持",
        feature2Desc: "支持 SMB、NFS、AFP、WebDAV 协议，满足各种网络存储需求。",
        feature3Title: "安全原生",
        feature3Desc: "基于原生 Swift 构建。密码安全存储于系统钥匙串中。",
        feature4Title: "流光玻璃界面",
        feature4Desc: "采用现代 macOS 流光玻璃设计语言，美观与实用并重。",
        feature5Title: "开机自启",
        feature5Desc: "随系统自动启动，随时待命。",
        feature6Title: "菜单栏常驻",
        feature6Desc: "常驻菜单栏，一键挂载或卸载任意服务器。",
        feature8Title: "VPN 感知",
        feature8Desc: "自动检测 VPN 路由，连接 VPN 时自动挂载，断开时自动卸载。",
        feature9Title: "睡眠/唤醒重连",
        feature9Desc: "睡眠前优雅断开挂载，唤醒后自动恢复所有连接。",
        feature10Title: "链接分享",
        feature10Desc: "通过 netmounter:// 链接分享服务器配置，团队一键导入。",
        feature11Title: "智能通知",
        feature11Desc: "挂载成功、失败、恢复时即时推送通知，支持从通知重试。",
        feature12Title: "僵尸挂载自愈",
        feature12Desc: "自动检测无响应的挂载点并恢复，无需手动干预。",
        protocolsTitle: "支持的协议",
        protocolSmb: "Windows 及 NAS 文件共享",
        protocolNfs: "Linux 及 Unix 文件共享",
        protocolAfp: "Apple 文件共享 (旧版)",
        protocolWebdav: "Nextcloud、ownCloud 等",
        comparisonTitle: "为什么选择 NetMounter？",
        comparisonFeature: "功能",
        comparisonMenuBar: "菜单栏应用",
        comparisonAutoMount: "按网络自动挂载",
        comparisonDiscovery: "网络发现",
        comparisonMultiProtocol: "多协议 (SMB/NFS/AFP/WebDAV)",
        comparisonBrew: "Homebrew 安装",
        comparisonFree: "免费开源",
        comparisonModernUI: "流光玻璃界面",
        comparisonKeychain: "钥匙串集成",
        comparisonVPN: "VPN 感知自动挂载",
        comparisonSleepWake: "睡眠/唤醒重连",
        comparisonURLScheme: "链接分享",
        comparisonNotifications: "挂载通知",
        comparisonLaunchLogin: "开机自启",
        footerRights: "保留所有权利。"
    }
};

let currentLang = 'en';

document.addEventListener('DOMContentLoaded', () => {
    const langToggleBtn = document.getElementById('lang-toggle');

    langToggleBtn.addEventListener('click', () => {
        currentLang = currentLang === 'en' ? 'zh' : 'en';
        updateLanguage();
    });

    // Optional: Auto-detect browser language
    if (navigator.language.startsWith('zh')) {
        currentLang = 'zh';
        updateLanguage();
    }
});

function updateLanguage() {
    const elements = document.querySelectorAll('[data-i18n]');
    const content = translations[currentLang];

    // Update text content
    elements.forEach(element => {
        const key = element.getAttribute('data-i18n');
        if (content[key]) {
            element.textContent = content[key];
        }
    });

    // Update button text
    const langToggleBtn = document.getElementById('lang-toggle');
    langToggleBtn.textContent = currentLang === 'en' ? '中文' : 'English';
}
