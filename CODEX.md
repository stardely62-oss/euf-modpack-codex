# Установка и обновление Codex

Текущий профиль пользователя: `C:\Users\Euf\AppData\Roaming\.minecraft\versions\test`.

Закройте Minecraft, распакуйте архив с заменой файлов и запустите
**`install-modpack.bat`**. Обычный запуск теперь устанавливает и обновляет моды
строго в `%APPDATA%\.minecraft\versions\test\mods`. `install-test.bat`
выполняет ту же установку. Общая `.minecraft\mods` и другие версии не меняются.
В TLauncher запускайте профиль `test` с его собственной папкой игры.

Требуется Minecraft 1.21.1, NeoForge 21.1.264+ и Java 21. Скрипт определяет
загрузчик по библиотекам, аргументам запуска и наследуемым профилям.

Для отдельной установки в `%APPDATA%\.minecraft-codex-neoforge-1.21.1`
предусмотрен дополнительный `install-isolated.bat`; обычный установщик этот
каталог не использует.

Сборки: https://github.com/stardely62-oss/euf-modpack-codex/releases/tag/pack-neoforge
Релизы модов NeoForge используют тег `neoforge-dev`. Прежние Fabric-релизы
и старый manifest сохранены отдельно. Проекты Claude не изменяются.
