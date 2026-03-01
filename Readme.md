# iOS-SimpleAutoClicker
一个简易的iOS连点器

## 功能
* 模拟单次点击（间隔0.05s - 2.00s）
* 最多同时设置10个点击位置

## 要求
* iOS 14.0+
* LiveContainer / Sideloadly / TrollFools 注入
* MSHookMessageEx (ElleKit或其他替代品)

## 使用方法
### LiveContainer
* 只给单个App注入
  * 在模块页面新建文件夹（或打开现有文件夹），导入本dylib
  * 回到App列表，长按你的App，选择设置，模块文件夹处选择刚刚的文件夹
* 全局注入
  * 直接在模块页面根目录导入本dylib

### Sideloadly
* 将解密的IPA拖入Sideloadly
* 点开Advanced Options，勾选Inject dylibs/frameworks
* 添加dylib，勾选Subsitute（如果无效，手动导入ellekit）
* 点击Start

## 实现
* 改进的[ZSFakeTouch](https://github.com/Roshanzs/ZSFakeTouch)（基于[KIF](https://github.com/kif-framework/KIF)测试框架）

## 许可
MIT