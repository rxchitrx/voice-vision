from pathlib import Path
from PIL import Image, ImageDraw


def make(folder: Path, columns: int, thumb_width: int):
    files = sorted(folder.glob("page-*.png"), key=lambda p: int(p.stem.split("-")[-1]))
    thumbs = []
    for index, path in enumerate(files, start=1):
        image = Image.open(path).convert("RGB")
        height = int(image.height * thumb_width / image.width)
        image.thumbnail((thumb_width, height))
        tile = Image.new("RGB", (thumb_width + 20, height + 45), "white")
        tile.paste(image, (10, 30))
        ImageDraw.Draw(tile).text((10, 8), f"Page {index}", fill="black")
        thumbs.append(tile)

    rows = (len(thumbs) + columns - 1) // columns
    cell_width = max(t.width for t in thumbs)
    cell_height = max(t.height for t in thumbs)
    sheet = Image.new("RGB", (columns * cell_width, rows * cell_height), "#dddddd")
    for index, thumb in enumerate(thumbs):
        sheet.paste(thumb, ((index % columns) * cell_width, (index // columns) * cell_height))
    sheet.save(folder / "contact.png")


make(Path("document_updates/render_ieee"), 2, 420)
make(Path("document_updates/render_report"), 3, 320)
