@echo off
rem Terra Nova Viewer en direct : la camera suit le jeu qui tourne (prototype).
rem Lance d'abord le jeu (avec Terra Nova Plus, Display HD + Widescreen TRUE pour le cockpit), entre en mission,
rem puis lance ce fichier. Clic dans la fenetre = prendre la souris (on joue depuis elle), Y ou Pause = curseur.
python -u "%~dp0live\live_bridge.py" --launch --hud --play --fov 91.5 --res 1696x960
rem la fenetre se ferme avec le visualiseur ; elle reste ouverte seulement si le pont a plante
if errorlevel 1 pause
