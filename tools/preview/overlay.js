/** Harness nakładki: prawdziwy AssistantOverlay na atrapie portu chrome.runtime. */

const listeners = { message: [], disconnect: [] };
let failNext = false;

globalThis.chrome = {
  runtime: {
    connect: () => ({
      postMessage: ({ id }) => {
        if (failNext) {
          setTimeout(() => listeners.message.forEach((f) => f({ type: 'error', id, error: 'Most nie działa — uruchom `npm run assistant`' })), 300);
          return;
        }
        const answer = 'RPO to Recovery Point Objective — maksymalna ilość danych mierzona w czasie, jaką akceptujemy do utracenia przy awarii. RPO 15 minut oznacza replikację co najwyżej kwadrans wstecz.';
        let i = 0;
        const tick = () => {
          if (i >= answer.length) {
            listeners.message.forEach((f) => f({ type: 'done', id, text: answer, durationMs: 2340 }));
            return;
          }
          const chunk = answer.slice(i, i + 7);
          i += 7;
          listeners.message.forEach((f) => f({ type: 'delta', id, text: chunk }));
          setTimeout(tick, 45);
        };
        setTimeout(tick, 700);
      },
      onMessage: { addListener: (f) => listeners.message.push(f) },
      onDisconnect: { addListener: (f) => listeners.disconnect.push(f) },
      disconnect: () => {},
    }),
  },
};

const { AssistantOverlay } = await import('/extension/content/overlay.js');

// `onAsk` udaje content script: w rozszerzeniu dokłada tu kontekst z transkrypcji.
const overlay = new AssistantOverlay({
  onAsk: (question) => {
    failNext = false;
    overlay.ask({ question, speaker: 'Ty', prompt: question, auto: false });
  },
}).mount();
overlay.setBridgeState('ok', 'gotowy');

document.getElementById('q1').addEventListener('click', () => {
  failNext = false;
  overlay.ask({ question: 'Co oznacza skrót RPO w kontekście backupów?', speaker: 'Marta', prompt: 'x' });
});
document.getElementById('q2').addEventListener('click', () => {
  failNext = false;
  overlay.ask({ question: 'Ile kosztuje RDS miesięcznie przy Multi-AZ?', speaker: 'Jan', prompt: 'x' });
});
document.getElementById('err').addEventListener('click', () => {
  failNext = true;
  overlay.ask({ question: 'Czy most w ogóle działa?', speaker: 'Anna', prompt: 'x' });
});
