Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
pythonwPath = """" & baseDir & "\.venv\Scripts\pythonw.exe"""
command = pythonwPath & " -m src.tray.tray_app"

shell.CurrentDirectory = baseDir
shell.Run command, 0, False