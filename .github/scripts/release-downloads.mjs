import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function releaseDownloads(repositoryUrl, tag, appVersion, scope = 'all') {
  const [version, build] = appVersion.split('+');
  const base = `${repositoryUrl}/releases/download/${encodeURIComponent(tag)}`;
  const link = (label, name) => `[${label}](${base}/${encodeURIComponent(name)})`;
  const rows = [
    ['Android', link('通用 APK / Universal', `VeneraX-${version}.apk`), [
      link('ARM64', `VeneraX-${version}-arm64-v8a.apk`),
      link('ARMv7', `VeneraX-${version}-armeabi-v7a.apk`),
      link('x86_64', `VeneraX-${version}-x86_64.apk`),
    ].join(' · ')],
    ['Windows', link('安装版 / Installer', `VeneraX-${version}-windows-installer.exe`),
      link('便携版 / Portable ZIP', `VeneraX-${version}-windows.zip`)],
    ['macOS', link('DMG', `VeneraX-${appVersion}.dmg`), '—'],
    ['iOS', link('未签名 IPA / Unsigned', `VeneraX-ios-${appVersion}.ipa`), '—'],
    ['Linux', [
      link('AppImage x86_64', `VeneraX-${version}-x86_64.AppImage`),
      link('AppImage ARM64', `VeneraX-${version}-aarch64.AppImage`),
    ].join(' · '), [
      link('Debian x86_64', `VeneraX-${version}-amd64.deb`),
      link('Debian ARM64', `VeneraX-${version}-arm64.deb`),
      link('Arch x86_64', `VeneraX-${version}-${build}-x86_64.pkg.tar.zst`),
    ].join(' · ')],
    ['HarmonyOS', link('未签名 HAP / Unsigned', `VeneraX-${appVersion}-harmonyos-unsigned.hap`),
      link('x64 模拟器 / Emulator', `VeneraX-${appVersion}-harmonyos-emulator-x64-unsigned.hap`)],
  ];
  if (scope === 'mobile') {
    return [
      '## 下载安装 / Downloads', '',
      '本次预览版提供 Android 和鸿蒙安装包。 / This preview includes Android and HarmonyOS.', '',
      '| 平台 / Platform | 安装包 / Package | 其他版本 / Alternatives |',
      '| --- | --- | --- |',
      ...rows.filter(([platform]) => platform === 'Android' || platform === 'HarmonyOS')
        .map(row => `| ${row.join(' | ')} |`), '',
      '不确定 Android 架构时选通用 APK。鸿蒙真机安装前需自行签名。',
      'Use the universal APK if unsure of your Android architecture. Sign the HarmonyOS HAP before installing it on a device.', '',
    ].join('\n');
  }
  return [
    '## 下载安装 / Downloads',
    '',
    '**手动安装或更新请从下表选择完整安装包。** 不确定 Android 架构时请选择通用 APK。',
    '**For manual installs or updates, choose a full package below.** Use the universal APK if unsure of your Android architecture.',
    '',
    '> `.patch` 和 `update-manifest.json` 仅供应用自动更新使用，无法直接安装，无需手动下载。',
    '> `.patch` files and `update-manifest.json` are for in-app updates only. They cannot be installed manually.',
    '',
    '| 平台 / Platform | 安装包 / Package | 其他版本 / Alternatives |',
    '| --- | --- | --- |',
    ...rows.map(row => `| ${row.join(' | ')} |`),
    '',
    'iOS IPA 和 HarmonyOS HAP 均未签名，安装前需自行签名。 / iOS IPA and HarmonyOS HAP packages require signing before installation.',
    '',
    '---',
    '',
  ].join('\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.stdout.write(releaseDownloads(...process.argv.slice(2)));
}
