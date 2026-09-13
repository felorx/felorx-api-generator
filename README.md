# Felorx SDK Generator

一个用于生成 Felorx API 客户端代码的工具，支持多种编程语言。

## 功能

- 从远程 API 下载 Swagger JSON 规范
- 使用 OpenAPI Generator 生成客户端代码
- 支持多种编程语言：Dart、TypeScript (Axios)、Go
- **Dart SDK 版本号管理**：生成前从 `felorx_api_client/pubspec.yaml` 读取版本号，生成后保持版本号不变
- 自动修复生成的 pubspec.yaml 文件（确保 `resolution: workspace` 字段存在）
- 自动运行 `dart run build_runner build --delete-conflicting-outputs` 生成 Dart 序列化代码
- 自动安装依赖（Dart: `dart pub get`，TypeScript: `yarn install`，Go: `go mod tidy`）

## 安装

```bash
cd packages/api/felorx_sdk_generator
dart pub get
```

## 使用方法

### 构建 Dart SDK

```bash
dart run bin/felorx_sdk_generator.dart dart
```

### 构建 TypeScript Axios SDK

```bash
dart run bin/felorx_sdk_generator.dart axios
```

### 构建 Go SDK

```bash
dart run bin/felorx_sdk_generator.dart go
```

### 构建所有支持的 SDK

```bash
dart run bin/felorx_sdk_generator.dart build
```

### 选项

- `--verbose` / `-v`: 显示详细输出
- `--swagger-url <url>`: 指定 Swagger JSON URL（默认: https://dev.api.felorx.com/swagger/v1/swagger.json）
- `--output-dir <dir>`: 指定输出目录
  - `dart` 命令默认: `../felorx_api_client`
  - `axios` 命令默认: `../felorx-api-axios`
  - `go` 命令默认: `../felorx-api-go`

### 示例

```bash
# 使用默认设置构建 Dart SDK
dart run bin/felorx_sdk_generator.dart dart

# 构建 TypeScript Axios SDK
dart run bin/felorx_sdk_generator.dart axios

# 构建 Go SDK
dart run bin/felorx_sdk_generator.dart go

# 构建所有 SDK
dart run bin/felorx_sdk_generator.dart build

# 使用自定义 URL 和输出目录
dart run bin/felorx_sdk_generator.dart dart \
  --swagger-url https://api.felorx.com/swagger/v1/swagger.json \
  --output-dir ../my_api_client

# 使用自定义输出目录构建 Axios SDK
dart run bin/felorx_sdk_generator.dart axios \
  --output-dir ../my_axios_client

# 使用自定义输出目录构建 Go SDK
dart run bin/felorx_sdk_generator.dart go \
  --output-dir ../my_go_client

# 显示详细输出
dart run bin/felorx_sdk_generator.dart build --verbose
```

## 修复的问题

### Responses 范围门禁

所有生成入口在启动 Java 前校验 Swagger：必须包含 `/api/ai/v1/responses` 的创建、查询、删除、取消、输入项分页、压缩和输入 token 计数七个核心操作。旧 `/api/ai/openai` 别名不能替代规范路径；AI Files/Vector Stores 资源路径和对应资源模型被拒绝。此检查不受 `skipValidateSpec` 影响。

生成后还会检查源码及残留资源文档，拒绝 File Search/Vector Store 客户端、未检查的符号链接或空输出；普通应用文件 API 和模型的内联文件输入不受影响。若当前 Swagger 尚未提供完整 Responses 契约，需要先补齐 API 再生成，不能跳过门禁把不完整 SDK 当成发布产物。

`dart test` 执行离线门禁测试。显式设置 `FELORX_SDK_GENERATOR_LIVE=1` 后运行 `dart test test/sdk_generation_scope_integration_test.dart`，使用本地 Java/JAR 和仓库配置在临时目录实际生成 Dart、Go、TypeScript Axios，检查七个操作方法及资源范围；测试结束清理临时 SDK，不修改正式客户端目录。

### 版本号问题（Dart SDK）

对于 Dart SDK，版本号处理逻辑如下：
- **生成前**：从 `felorx_api_client/pubspec.yaml` 中读取现有版本号
- **生成后**：保持版本号不变，不会从 Swagger JSON 更新版本号
- 这样可以确保版本号由开发者手动管理，而不是自动从 API 版本更新

### resolution 字段问题

生成的 `pubspec.yaml` 文件中会确保包含 `resolution: workspace` 字段（用于 monorepo 工作区解析）。

## 开发

实际 Host 导出的规范可通过 `FELORX_EXPORTED_SWAGGER` 指定。设置
`FELORX_SDK_GENERATOR_LIVE=1` 后运行
`dart test test/sdk_generation_scope_integration_test.dart test/responses_swagger_export_test.dart`，
会校验完整规范并生成 Dart、Go、TypeScript Axios 客户端。
额外设置 `FELORX_SDK_COMPILE=1` 会安装生成客户端依赖并执行 Dart 序列化代码生成、静态分析、Responses JSON 往返及 SSE 认证/取消 HTTP 验证、Go 编译、TypeScript 编译；需要对应工具链及网络。
`FELORX_SDK_KEEP_OUTPUT=1` 可保留临时输出以诊断失败。

Dart 的 Responses `input` 与 `tool_choice` 联合类型映射为原生 `Object`，
调用者可传入文本、消息对象数组或工具选择对象，序列化保留原始 JSON。
OpenAPI 保留完整联合类型，服务端沿用既有请求校验。SDK 对这两个字段不提供静态分支约束。
Host 会为原有重复 operationId 添加 HTTP 方法与路径后缀，相关生成方法名因此变化，HTTP 路径不变；升级正式客户端时需核对这些调用点。

实际 Host 规范为 Dart 生成 `createResponseStream` 和 `createResponseLegacyStream`。
普通创建方法仅用于 JSON 响应；流式方法强制设置 `stream=true`，保留传入请求对象，
返回包含事件类型和完整 JSON 的 `Stream<FelorxResponseStreamEvent>`。
通过 `client.setBearerAuth('FelorxBearer', token)` 配置认证，Provider 使用
`xFelorxAiProvider` 参数。取消订阅会中止该请求，也支持调用者传入 `CancelToken`；
终止事件后关闭流，未收到终止事件的断连作为错误返回。
HTTP 错误以带状态和有界 JSON 正文的 `DioException` 返回，流内 `error` 事件保留为终止事件。
SSE 解码限制单帧字符数，支持拆分 UTF-8、CR/LF/CRLF、注释和多行 data。
使用 `createResponseRawStream(body: ...)` 可保留 DTO 未声明的原生扩展字段，
适用于运行时构造的完整 Responses JSON。设置 `FELORX_GENERATED_SDK_PATH`
可在导出契约测试中同时检查正式 SDK 目录的核心范围。

Go 生成流程现在附带 `responses_stream.go`，提供
`ReadResponsesStream(ctx, body, emit)`。它接管并关闭 `io.ReadCloser`，
同步调用消费者以保持背压，支持 UTF-8 分片、CR/LF/CRLF、多行 SSE，
单帧上限为 8 MiB；没有终态的 EOF 作为错误返回。事件字段使用
`json.RawMessage`，避免大整数被转换成浮点数。取消上下文或消费者返回错误
会关闭输入流。`StreamResponses(ctx, options, body, emit)` 发起完整流式请求，
`FelorxResponseStreamOptions` 配置完整 Endpoint、BearerToken、Provider 和可选 HTTPClient。
它复用客户端传输/超时配置，禁止生成请求重定向，在请求副本上设置 `stream=true`，
并检查响应为 SSE。非成功状态返回 `FelorxResponseHTTPError`，其 `Error()` 不含服务端正文，
`Body` 仅保留不超过 64 KiB 的有效 JSON 供调用者显式检查。
生成的 `APIClient.CreateResponseRawStream` 和 `CreateResponseLegacyRawStream`
会复用 `Servers`/`OperationServers`、Host/Scheme、HTTPClient、默认请求头和 UserAgent。
Bearer 优先取 `ContextAccessToken`，否则使用默认 Authorization；显式 Provider
覆盖默认 `X-Felorx-Ai-Provider`。两种入口都保留原生 JSON 扩展字段。
`dart test test/go_responses_support_test.dart`
在有 Go 工具链时实际编译并执行管道/取消/异常帧测试；无工具链时明确跳过。

TypeScript Axios 生成流程附带并导出 `FelorxResponsesSseDecoder`。
通过 `push(Uint8Array)` 逐个消费事件，读取结束后调用 `finish()` 检查终态；
支持严格 UTF-8、BOM、CR/LF/CRLF、多行 SSE 和 8 MiB 帧上限。
事件的 `data` 使用标准 JavaScript JSON 语义，`rawData` 保留精确原始 JSON，
处理超出安全整数范围的数值时应读取原文。`streamResponses` 提供 Axios HTTP 流与取消封装。
`dart test test/axios_responses_support_test.dart` 在 Node 22.6+ 上执行原生
TypeScript 运行测试；实际完整 SDK 编译仍由 live 生成门禁负责。

### 项目结构

```
felorx_sdk_generator/
├── bin/
│   └── felorx_sdk_generator.dart  # 命令行入口
├── lib/
│   ├── felorx_sdk_generator.dart  # 库导出
│   └── src/
│       ├── generator.dart         # SDK 生成器
│       ├── swagger_downloader.dart # Swagger 下载器
│       └── pubspec_fixer.dart     # Pubspec 修复器
├── configs/                       # OpenAPI Generator 配置
├── templates/                     # 代码生成模板
└── pubspec.yaml
```

## 依赖

Axios 生成产物导出 `readResponsesStream(reader, emit, signal?)`，接受
`ReadableStream<Uint8Array>.getReader()`，接管 reader 的取消和锁释放。
逐个等待异步 `emit`，不提前读取下一块；终态、解析失败、回调失败或取消均清理流。
取消不会强制终止回调自身的异步工作，回调应将同一个 signal 传给其下游操作。
`streamResponses(options, body, emit)` 支持 Axios fetch（默认）和 Node http 适配器，
使用 endpoint、bearerToken、provider、headers、client、adapter、signal 选项。
强制 stream=true，保留扩展 JSON，不修改原始对象；禁止自动重定向，限制请求 8 MiB、错误 JSON 64 KiB。
`FelorxResponseHTTPError` 提供 statusCode 和显式 body，错误消息不携带认证或服务端正文。
生成器要求 Axios >=1.20，以匹配构建出的响应类型泛型及 fetch 流支持。live Axios 门禁现在运行真实本地 HTTP 测试，
覆盖 fetch/http 两条路径、认证、provider、扩展字段、取消和连接释放。
这些测试在 Node 执行；浏览器原生环境与正式 SDK 更新仍待验收。

完整 Host 合约还生成 `ResponsesStreamApi extends ResponsesApi`，保留原有非流式方法，
增加 `createResponseRawStream({body, xFelorxAiProvider?}, emit, options?)` 和兼容路由方法
`createResponseLegacyRawStream`。构造参数与 `ResponsesApi` 一致，复用 Configuration、
Axios 实例、异步 accessToken、baseOptions 和每次请求的选项；流请求始终强制 POST/SSE。
本地 HTTP 测试覆盖两路由 × 三种服务器来源 × 四种认证来源，共 24 个组合。
仅包含最小范围操作、没有完整 Responses 类型的测试规范仍可生成独立 HTTP helper，
不会导出依赖不存在的模型或 API 类的适配器；完整 Host 合约门禁强制要求类适配器存在。

真实浏览器验收可运行 `node test/fixtures/responses_browser_server.cjs <已构建的 Axios SDK 绝对目录>`，
然后用浏览器打开输出的 localhost 地址。测试只使用本地服务及虚构 token，页面显示 PASS/FAIL，
覆盖原生 fetch/ReadableStream、中文事件、终态关闭、认证、取消、错误和重定向。
结束后停止该进程；此脚本不访问外部模型或 API。

- `args`: 命令行参数解析
- `http`: HTTP 客户端
- `yaml`: YAML 解析
