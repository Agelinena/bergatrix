"""Matéria salva: a API avisa o worker de coleta, que baixa as imagens dela
para o servidor na hora (elas ficam mesmo que o site apague, e a limpeza
nunca apaga imagem de matéria salva)."""
KEEP_IMAGES_KEY = "berganews:keep:images"
