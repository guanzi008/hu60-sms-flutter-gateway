# Hu60 SMS Gateway（Flutter 独立 APK）

此工程将“短信网关 API”能力重构为可安装的 Android APK，核心逻辑如下：

1. 提供 `POST /sms` 接口
2. `apikey` 鉴权
3. 单号发送频率控制（`rateLimitSec`）
4. 单号日发送上限（`rateLimitDaily`）
5. 全局日发送上限（`globalDailyLimit`）
6. 可选 SIM 卡槽配置（`slot`）
7. Android 运行时权限管理（发送短信 / 电话状态）
8. 请求日志持久化 + 请求统计 + 清空/复制日志
9. IP 白名单（支持 CIDR/通配符）
10. 请求日志和运行日志导出到本地文件
11. 锁屏保活提示与前后台恢复逻辑（返回前台时自动恢复服务）

## 运行链路

1. 安装 Flutter 与 Android 工具链
2. 安装依赖 `flutter pub get`
3. 生成 apk `flutter build apk --release`
4. 通过 USB 安装 apk 到测试机并授予短信/电话权限
5. 在应用内设置 `apikey`、端口和限流参数，启动服务
6. 日志区可清空与复制到剪贴板，便于排障
7. 日志导出（按按钮导出运行日志/请求日志到本地可读文件）

## 接口

### 请求

- 方法: `POST`
- 路径: `/sms`
- Content-Type: `application/x-www-form-urlencoded` 或 `application/json`
- 参数:
  - `apikey`（必填）
  - `mobile`（必填）
  - `text`（必填）

### 响应

- 成功: `{"code":200,"message":"SMS sent successfully"}`
- 参数缺失: `{"code":400,"message":"Missing required field: apikey / mobile / text"}`
- API Key 错误: `{"code":403,"message":"Invalid API Key"}`
- 频率限制: `{"code":429,"message":"触发频率限制..."}`
- 发送失败: `{"code":500,"message":"发送失败: ..."}`

## 项目结构

- `lib/main.dart`：Flutter 页面、服务控制、持久化配置、日志与统计、频控逻辑
- `android/app/src/main/kotlin/com/hu60/smsgateway/MainActivity.kt`：MethodChannel + Android 短信发送与权限实现
- `android/`：Gradle 与 Android 工程文件

## 注意事项

- Android 13+ 对短信、后台运行与电池优化有额外策略限制，实际机型可能需要手动放行
- 该程序面向自建自用场景，请遵守相关短信发送合规要求
