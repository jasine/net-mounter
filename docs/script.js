const translations = {
    en: {
        heroTitle: "Seamless Network Mounting",
        heroSubtitle: "The lightweight, menu-bar essential for macOS. Auto-mount network shares effortlessly.",
        downloadBtn: "Download for macOS",
        versionInfo: "v1.0.0 • macOS 14+",
        feature1Title: "Auto-Mount",
        feature1Desc: "Automatically detects your network environment and mounts the right shares instantly.",
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
        protocolsTitle: "Supported Protocols",
        protocolSmb: "Windows & NAS file sharing",
        protocolNfs: "Linux & Unix file sharing",
        protocolAfp: "Apple file sharing (legacy)",
        protocolWebdav: "Nextcloud, ownCloud & more",
        footerRights: "All rights reserved."
    },
    zh: {
        heroTitle: "无感网络挂载体验",
        heroSubtitle: "专为 macOS 打造的轻量级菜单栏工具。自动挂载网络共享，从未如此轻松。",
        downloadBtn: "下载 macOS 版本",
        versionInfo: "v1.0.0 • macOS 14+",
        feature1Title: "智能自动挂载",
        feature1Desc: "自动识别网络环境，即时挂载对应的网络共享，无缝衔接。",
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
        protocolsTitle: "支持的协议",
        protocolSmb: "Windows 及 NAS 文件共享",
        protocolNfs: "Linux 及 Unix 文件共享",
        protocolAfp: "Apple 文件共享 (旧版)",
        protocolWebdav: "Nextcloud、ownCloud 等",
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

