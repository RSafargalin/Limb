<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/readme-logo-light-1200.png">
    <source media="(prefers-color-scheme: light)" srcset="./assets/readme-logo-dark-1200.png">
    <img alt="Limb" src="./assets/readme-logo-dark-1200.png" width="360">
  </picture>
</h1>

Limb — Swift-пакет для создания серверов [Model Context Protocol](https://modelcontextprotocol.io/).
Сервер запускается локально, а MCP-клиент обменивается с ним сообщениями через стандартный ввод и вывод (stdio).
Limb находится на стадии предварительной версии.

## Возможности

- Регистрация инструментов, ресурсов, шаблонов URI и промптов.
- Описание инструментов через `@Tool` или вручную через `ToolDefinition`.
- Генерация JSON Schema из Swift-типов с `@Schema` и проверка аргументов перед вызовом обработчика.
- Подписки, уведомления, прогресс и отмена в пределах возможностей используемой ревизии MCP.
- Вызовы сервера в памяти через `LimbTesting` для тестов вашего приложения.

| Транспорт | Ревизии MCP |
| --- | --- |
| stdio | `2026-07-28`, `2025-11-25`, `2025-06-18`, `2025-03-26` |

## Требования

Для локального примера ниже нужны macOS 26 или новее и Swift 6.2 или новее.

## Установка

Добавьте Limb в зависимости вашего пакета и подключите продукт `Limb` к нужной цели.
Ниже целиком манифест `Package.swift` для примера `EchoServer`.

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EchoServer",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/RSafargalin/Limb.git", exact: "0.0.1-rc"),
    ],
    targets: [
        .executableTarget(
            name: "EchoServer",
            dependencies: [.product(name: "Limb", package: "Limb")]
        ),
    ]
)
```

## Пример stdio-сервера

Создайте `Sources/EchoServer/EchoServer.swift` рядом с манифестом.

```swift
import Limb

/// Возвращает переданный текст.
@Tool(readOnly: true)
struct Echo {
    func call(text: String) -> String {
        text
    }
}

@main
struct EchoServer {
    static func main() async throws {
        let server = try Server(name: "echo-server", version: "1.0.0") {
            Echo()
        }
        await server.run()
    }
}
```

Из каталога пакета выполните `swift build`. Команда `swift build --show-bin-path`
выведет путь к каталогу, в котором находится бинарник `EchoServer`.

Для MCP-клиента, который использует конфигурацию `mcpServers`, добавьте запись
и подставьте абсолютный путь к бинарнику.

```json
{
  "mcpServers": {
    "echo": {
      "command": "/absolute/path/to/EchoServer"
    }
  }
}
```

После подключения вызовите инструмент `echo` с аргументом `{"text":"Привет"}`.
Сервер вернёт переданный текст.

## Вклад в проект

Сборка из исходников, оформление баг-репортов и порядок подачи изменений описаны
в [CONTRIBUTING.md](CONTRIBUTING.md).

## Лицензия

Limb распространяется по лицензии [Apache License 2.0](LICENSE).
