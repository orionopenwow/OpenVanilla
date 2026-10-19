
const capacity = 3600; // The latest hour at one sample per second.
const rows = new Array(capacity);
let head = '', next = 0, count = 0;
export function journalText() {
    let csv = head;
    for (let i = 0; i < count; i++) csv += rows[(next - count + i + capacity) % capacity];
    return csv;
}
export function begin(header) {
    if (!head) head = header;
    window.__wenilla_fps_journal = { text: journalText, download };
    if (document.getElementById('wenilla-journal-download')) return;
    const button = document.createElement('button');
    button.id = 'wenilla-journal-download';
    button.textContent = 'download FPS journal';
    button.title = 'Download the latest hour of recorded performance samples';
    button.style.cssText = 'position:fixed;bottom:.5rem;right:.5rem;z-index:30';
    button.addEventListener('click', download);
    document.body.appendChild(button);
}
export function append(row) {
    rows[next] = row;
    next = (next + 1) % capacity;
    count = Math.min(count + 1, capacity);
}
function download() {
    const url = URL.createObjectURL(new Blob([journalText()], {type: 'text/csv;charset=utf-8'}));
    const link = document.createElement('a');
    link.href = url;
    link.download = 'fps-journal.csv';
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
}
