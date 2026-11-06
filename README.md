# ⚡ Galaxy Continuity (macOS + Samsung Galaxy)

Нативная экосистема непрерывности («Continuity») для связки **macOS** и **Samsung Galaxy** (Android).

Полноценная замена Apple Continuity: общий буфер обмена, быстрая передача файлов (Quick Drop / AirDrop), уведомления с телефона на Маке, поиск телефона и бесшовное сопряжение.

---

## 🚀 Возможности

1. **📋 Universal Clipboard (Общий буфер обмена)**
   * Скопировали текст или ссылку на Маке — она мгновенно доступна на Galaxy.
   * Скопировали на Galaxy — вставили на Маке через `Cmd + V`.
   * Автоматическая синхронизация в фоне с защитой от эхо-петель.

2. **⚡ Quick Drop (Аналог AirDrop)**
   * Перетащите любой файл (фото, видео, документы) на значок в строке меню Мака — файл моментально отправляется на Galaxy.
   * Отправляйте файлы с Galaxy прямо в папку `~/Downloads/GalaxyContinuity` на Маке на полной скорости локального Wi-Fi (без облаков и ограничений).

3. **📱 Instant Web Companion (PWA / Браузер)**
   * **Нулевая настройка:** не обязательно сразу компилировать APK!
   * Откройте Galaxy Continuity на Маке, нажмите **«Pair Phone»** и наведите камеру Samsung Galaxy на появившийся **QR-код**.
   * Телефон откроет интерфейс в стиле Samsung One UI с поддержкой буфера обмена, отправки файлов, индикатором заряда батареи и вибросигналом.

4. **🤖 Полное нативное Android-приложение (Kotlin + Jetpack Compose)**
   * Исходный код в каталоге `android/`.
   * Фоновый сервис (`ForegroundService`), который держит связь даже при заблокированном телефоне.
   * Пересылка системных уведомлений (Telegram, WhatsApp, звонки) на экран Mac.
   * Автоматический поиск Mac в локальной сети через mDNS / Apple Bonjour (`_galaxycontinuity._tcp.`).

5. **🔔 Find My Galaxy / Mac Ping**
   * Нажмите «Find Phone» на Маке — Galaxy завибрирует и воспроизведет звуковой сигнал.

---

## 🛠 Структура репозитория

```
galaxy-continuity/
├── mac/                               # Нативное приложение для macOS (Swift 5.9+, SwiftUI)
│   ├── Package.swift                  # Swift Package Manager
│   ├── Info.plist                     # Menu Bar Agent (LSUIElement)
│   ├── Sources/GalaxyContinuity/
│   │   ├── App.swift                  # Точка входа
│   │   ├── AppDelegate.swift          # Меню-бар (NSStatusItem + NSPopover)
│   │   ├── Models/                    # Состояние и протокол обмена
│   │   ├── Services/                  # Сокет-сервер, буфер обмена, Bonjour mDNS
│   │   ├── UI/                        # SwiftUI интерфейс (MenuBarView, Dropzone, QR)
│   │   └── WebCompanion/              # Встроенный OneUI Web Companion (HTML5/JS)
│   └── scripts/
│       ├── build_app.sh               # Сборка Release .app и установка в /Applications
│       └── generate_icon.swift        # Генератор космической иконки .icns
│
├── android/                           # Нативное Android-приложение (Kotlin + Jetpack Compose)
│   ├── build.gradle.kts
│   ├── app/
│   │   ├── AndroidManifest.xml
│   │   └── src/main/java/com/galaxycontinuity/app/
│   │       ├── MainActivity.kt        # Jetpack Compose интерфейс
│   │       ├── service/               # Фоновый сервис и пересылка уведомлений
│   │       └── network/               # mDNS клиент и WebSocket
│
└── shared/
    └── PROTOCOL.md                    # Спецификация сетевого протокола
```

---

## ⚡ Быстрый старт

### Шаг 1: Запуск на Mac
Приложение уже собрано и установлено в `/Applications/Galaxy Continuity.app`.
Вы можете запустить его командой:
```bash
open "/Applications/Galaxy Continuity.app"
```
В строке меню (рядом с часами) появится иконка со стрелками непрерывности.

### Шаг 2: Подключение Samsung Galaxy

#### Вариант А: Мгновенное подключение (без установки APK)
1. Убедитесь, что Mac и Galaxy подключены к одной Wi-Fi сети.
2. Нажмите на иконку **Galaxy Continuity** в строке меню Mac -> **«Pair Phone»**.
3. Наведите камеру Samsung Galaxy на появившийся QR-код.
4. Откроется интерфейс One UI — буфер обмена и передача файлов уже работают!

#### Вариант Б: Нативный APK (Android Studio)
1. Откройте папку `android/` в Android Studio.
2. Подключите Samsung Galaxy по проводу или Wi-Fi ADB.
3. Нажмите **Run** (зеленый треугольник).
4. Разрешите доступ к уведомлениям для автоматической пересылки на Mac.
