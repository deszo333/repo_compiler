const form = document.getElementById("compileForm");
const statusEl = document.getElementById("status");
const submitBtn = document.getElementById("submitBtn");
const presetEl = document.getElementById("preset");
const customExtensionsEl = document.getElementById("custom_extensions");

function updateCustomState() {
  const isCustom = presetEl.value === "custom";
  customExtensionsEl.disabled = !isCustom;
  customExtensionsEl.style.opacity = isCustom ? "1" : "0.6";
}

presetEl.addEventListener("change", updateCustomState);
updateCustomState();

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  submitBtn.disabled = true;
  statusEl.textContent = "Compiling repository...";
  const data = new FormData(form);

  try {
    const response = await fetch("/compile", {
      method: "POST",
      body: data,
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || "Compilation failed.");
    }

    const blob = await response.blob();
    const disposition = response.headers.get("content-disposition") || "";
    const match = disposition.match(/filename="?([^";]+)"?/i);
    const filename = match ? match[1] : "compiled_repo.txt";

    const url = window.URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.URL.revokeObjectURL(url);

    statusEl.textContent = "Download started.";
  } catch (error) {
    statusEl.textContent = error instanceof Error ? error.message : "Something went wrong.";
  } finally {
    submitBtn.disabled = false;
  }
});
