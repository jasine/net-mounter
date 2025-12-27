const translations = {
    en: {
        heroTitle: "Seamless Network Mounting",
        heroSubtitle: "The lightweight, menu-bar essential for macOS. Auto-mount SMB shares effortlessly.",
        downloadBtn: "Download for macOS",
        versionInfo: "v1.0.0 • macOS 14+",
        feature1Title: "Auto-Mount",
        feature1Desc: "Automatically detects your network environment and mounts the right shares instantly.",
        feature2Title: "Secure & Native",
        feature2Desc: "Built with native Swift APIs. Passwords securely stored in macOS Keychain.",
        feature3Title: "Liquid Design",
        feature3Desc: "A stunning, modern interface designed for macOS Sonoma and beyond.",
        footerRights: "All rights reserved."
    },
    zh: {
        heroTitle: "无感网络挂载体验",
        heroSubtitle: "专为 macOS 打造的轻量级菜单栏工具。自动挂载 SMB 共享，从未如此轻松。",
        downloadBtn: "下载 macOS 版本",
        versionInfo: "v1.0.0 • macOS 14+",
        feature1Title: "智能自动挂载",
        feature1Desc: "自动识别网络环境，即时挂载对应的网络共享，无缝衔接。",
        feature2Title: "安全原生",
        feature2Desc: "基于原生 Swift 构建。密码安全存储于系统钥匙串中。",
        feature3Title: "流光设计",
        feature3Desc: "采用现代 macOS 流光玻璃设计语言，美观与实用并重。",
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
