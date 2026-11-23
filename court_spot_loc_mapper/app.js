"use strict";

const X_MIN = -250, X_MAX = 250, Y_MIN = -52, Y_MAX = 418;
const court = document.getElementById("court");
const spotsLayer = document.getElementById("spots");
const list = document.getElementById("list");
const details = document.getElementById("details");
const labelInput = document.getElementById("label");
const xInput = document.getElementById("x");
const yInput = document.getElementById("y");
const addButton = document.getElementById("add");
const removeButton = document.getElementById("remove");
const saveButton = document.getElementById("save");
const status = document.getElementById("status");
const hint = document.getElementById("hint");
let spots = [];
let selected = -1;
let adding = false;
let dragging = null;

function setStatus(message, error = false) {
  status.textContent = message;
  status.classList.toggle("error", error);
}
function clamp(value, low, high) { return Math.min(high, Math.max(low, value)); }
function round(value) { return Math.round(value * 100) / 100; }
function xyFromPointer(event) {
  const rect = court.getBoundingClientRect();
  return {
    x: round(X_MIN + clamp((event.clientX - rect.left) / rect.width, 0, 1) * (X_MAX - X_MIN)),
    y: round(Y_MIN + clamp((event.clientY - rect.top) / rect.height, 0, 1) * (Y_MAX - Y_MIN)),
  };
}
function positionSpot(marker, loc) {
  marker.style.left = `${(loc.x - X_MIN) / (X_MAX - X_MIN) * 100}%`;
  marker.style.top = `${(loc.y - Y_MIN) / (Y_MAX - Y_MIN) * 100}%`;
}
function setAdding(value) {
  adding = value;
  addButton.classList.toggle("active", value);
  addButton.setAttribute("aria-pressed", String(value));
  hint.textContent = value ? "Click the court to place a new spot." : "Select a spot, or click Add spot and then click the court. Drag a spot to move it.";
  court.style.cursor = value ? "crosshair" : "default";
}
function render() {
  spotsLayer.replaceChildren();
  list.replaceChildren();
  spots.forEach((spot, index) => {
    const marker = document.createElement("div");
    marker.className = `spot${index === selected ? " selected" : ""}`;
    marker.setAttribute("role", "button");
    marker.setAttribute("aria-label", `${spot.label}, x ${spot.loc.x}, y ${spot.loc.y}`);
    const caption = document.createElement("span");
    caption.textContent = spot.label;
    marker.append(caption);
    positionSpot(marker, spot.loc);
    marker.addEventListener("pointerdown", event => {
      event.stopPropagation();
      event.preventDefault();
      setAdding(false);
      selected = index;
      dragging = { index, marker, pointerId: event.pointerId };
      marker.setPointerCapture(event.pointerId);
      syncSelection();
    });
    marker.addEventListener("pointermove", event => {
      if (!dragging || dragging.marker !== marker || dragging.pointerId !== event.pointerId) return;
      spot.loc = xyFromPointer(event);
      positionSpot(marker, spot.loc);
      xInput.value = spot.loc.x;
      yInput.value = spot.loc.y;
      setStatus("Unsaved changes");
    });
    marker.addEventListener("pointerup", event => {
      if (dragging && dragging.marker === marker && dragging.pointerId === event.pointerId) {
        dragging = null;
        render();
      }
    });
    marker.addEventListener("pointercancel", () => { dragging = null; render(); });
    spotsLayer.append(marker);

    const row = document.createElement("button");
    row.textContent = `${spot.label}  (${spot.loc.x}, ${spot.loc.y})`;
    row.classList.toggle("selected", index === selected);
    row.addEventListener("click", () => { selected = index; render(); });
    list.append(row);
  });
  syncSelection();
}
function syncSelection() {
  const spot = spots[selected];
  details.hidden = !spot;
  removeButton.disabled = !spot;
  for (const [index, marker] of [...spotsLayer.children].entries()) {
    marker.classList.toggle("selected", index === selected);
  }
  for (const [index, row] of [...list.children].entries()) {
    row.classList.toggle("selected", index === selected);
  }
  if (spot) {
    labelInput.value = spot.label;
    xInput.value = spot.loc.x;
    yInput.value = spot.loc.y;
  }
}
function nextLabel() {
  let number = 1;
  while (spots.some(spot => spot.label === `Spot ${number}`)) number++;
  return `Spot ${number}`;
}
addButton.addEventListener("click", () => setAdding(!adding));
court.addEventListener("pointerdown", event => {
  if (!adding || event.target.closest(".spot")) return;
  spots.push({ label: nextLabel(), loc: xyFromPointer(event) });
  selected = spots.length - 1;
  setAdding(false);
  setStatus("Unsaved changes");
  render();
  labelInput.focus();
  labelInput.select();
});
removeButton.addEventListener("click", () => {
  if (selected < 0) return;
  spots.splice(selected, 1);
  selected = Math.min(selected, spots.length - 1);
  setStatus("Unsaved changes");
  render();
});
labelInput.addEventListener("input", () => {
  if (selected < 0) return;
  spots[selected].label = labelInput.value;
  setStatus("Unsaved changes");
  // Keep the field focused while refreshing captions and the list.
  [...spotsLayer.children][selected].querySelector("span").textContent = labelInput.value;
  [...list.children][selected].textContent = `${labelInput.value}  (${spots[selected].loc.x}, ${spots[selected].loc.y})`;
});
for (const [input, axis, low, high] of [[xInput, "x", X_MIN, X_MAX], [yInput, "y", Y_MIN, Y_MAX]]) {
  input.addEventListener("input", () => {
    if (selected < 0) return;
    const value = Number(input.value);
    if (!input.value.trim() || !Number.isFinite(value) || value < low || value > high) {
      setStatus(`${axis.toUpperCase()} must be between ${low} and ${high}.`, true);
      return;
    }
    spots[selected].loc[axis] = round(value);
    setStatus("Unsaved changes");
    positionSpot([...spotsLayer.children][selected], spots[selected].loc);
    [...list.children][selected].textContent = `${spots[selected].label}  (${spots[selected].loc.x}, ${spots[selected].loc.y})`;
  });
}
async function save() {
  if (selected >= 0) {
    for (const [input, low, high, axis] of [[xInput, X_MIN, X_MAX, "X"], [yInput, Y_MIN, Y_MAX, "Y"]]) {
      const value = Number(input.value);
      if (!input.value.trim() || !Number.isFinite(value) || value < low || value > high) {
        return setStatus(`${axis} must be between ${low} and ${high}.`, true);
      }
    }
  }
  const labels = new Set();
  for (const spot of spots) {
    if (!spot.label.trim()) return setStatus("Every spot needs a label.", true);
    if (labels.has(spot.label)) return setStatus(`Duplicate label: ${spot.label}`, true);
    labels.add(spot.label);
  }
  saveButton.disabled = true;
  try {
    const response = await fetch("/api/mapping", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ spotList: spots }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Save failed.");
    setStatus(`Saved to ${result.saved}`);
  } catch (error) {
    setStatus(error.message, true);
  } finally {
    saveButton.disabled = false;
  }
}
saveButton.addEventListener("click", save);
document.addEventListener("keydown", event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
    event.preventDefault();
    save();
  }
  if (event.key === "Escape" && adding) setAdding(false);
});

fetch("/api/mapping")
  .then(response => { if (!response.ok) throw new Error("Could not load mapping."); return response.json(); })
  .then(data => { spots = data.spotList; render(); setStatus(`${spots.length} spot${spots.length === 1 ? "" : "s"} loaded.`); })
  .catch(error => setStatus(error.message, true));
