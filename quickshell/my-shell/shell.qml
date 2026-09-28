import Quickshell

ShellRoot {
    Variants {
        model: Quickshell.screens

        Scope {
            required property var modelData

            Launcher {
                targetScreen: modelData
            }

            TopBar {
                targetScreen: modelData
            }

            TimeWidget {
                 targetScreen: modelData



            }
        }
    }
}
