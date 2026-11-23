# Court spot mapper

Run with the project's Python 3.15 environment:

```sh
cd court_spot_loc_mapper
.venv/bin/python main.py output.json
.venv/bin/python main.py output.json --input existing.json
```

The editor opens in your browser. Click **Add spot**, then click the court to place it. Drag a spot to move it, or select it to edit its label and coordinates. Click **Save JSON** (or press Cmd/Ctrl+S) to write the output file. Keep the terminal running while editing; press Ctrl+C when finished.

The image maps left to right from X = −250 to 250 and top to bottom from Y = −52 to 418. The saved file uses this shape:

```json
{
  "spotList": [
    { "label": "Spot 1", "loc": { "x": 0, "y": 183 } }
  ]
}
```
