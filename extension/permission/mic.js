/**
 * Jednorazowe nadanie zgody na mikrofon.
 *
 * Dokument offscreen jest niewidoczny, więc nie może pokazać promptu Chrome.
 * Zgoda nadana raz na tej widocznej stronie obowiązuje dla całego origin
 * rozszerzenia — także dla offscreen.
 */

const button = document.getElementById('grant');
const status = document.getElementById('status');

function setStatus(text, variant) {
  status.textContent = text;
  status.className = `hero-chip${variant ? ` hero-chip--${variant}` : ''}`;
}

async function currentState() {
  try {
    const result = await navigator.permissions.query({ name: 'microphone' });
    return result.state;
  } catch {
    return 'prompt';
  }
}

async function request() {
  setStatus('pytam…');
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    for (const track of stream.getTracks()) track.stop();
    setStatus('przyznano — możesz zamknąć tę kartę', 'success');
    button.disabled = true;
    setTimeout(() => window.close(), 1500);
  } catch (error) {
    setStatus(error?.name === 'NotAllowedError' ? 'odmówiono' : 'błąd', 'danger');
  }
}

button.addEventListener('click', request);

currentState().then((state) => {
  if (state === 'granted') {
    setStatus('już przyznano', 'success');
    button.disabled = true;
  } else if (state === 'denied') {
    setStatus('zablokowano w ustawieniach Chrome', 'danger');
  }
});
