@echo off
REM Exports the item table for the GM panel Armory. Re-run after changing items in the database.
cd /d "%~dp0"
set "PYTHON_EXE=python"
"%PYTHON_EXE%" gen_items.py > gen_items_result.txt 2>&1
