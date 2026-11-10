(() => {
    const app = document.getElementById('exam-app');
    if (!app) return;

    const attemptId = app.dataset.attemptId;
    const timer = document.getElementById('exam-timer');
    const status = document.getElementById('save-status');
    const panels = [...document.querySelectorAll('.exam-question')];
    const navButtons = [...document.querySelectorAll('.question-nav button')];
    let current = 0;
    let submitStarted = false;
    const debounceTimers = new Map();
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || '';

    function valueFor(panel) {
        const type = panel.dataset.type;
        const inputs = [...panel.querySelectorAll('input, textarea')];
        if (type === 'multiple_choice' || type === 'true_false') {
            return panel.querySelector('input[type="radio"]:checked')?.value ?? '';
        }
        if (type === 'multiple_select') {
            return [...panel.querySelectorAll('input[type="checkbox"]:checked')].map(item => item.value).sort();
        }
        return inputs[0]?.value ?? '';
    }

    async function save(panel) {
        const answer = valueFor(panel);
        status.textContent = 'Saving…';
        try {
            const response = await fetch(`/api/attempt/${attemptId}/answer`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-CSRFToken': csrfToken },
                body: JSON.stringify({ question_id: panel.dataset.questionId, answer })
            });
            if (!response.ok) throw new Error('save failed');
            status.textContent = 'Saved';
            const index = panels.indexOf(panel);
            const hasAnswer = Array.isArray(answer) ? answer.length > 0 : answer !== '';
            navButtons[index]?.classList.toggle('answered', hasAnswer);
            return true;
        } catch {
            status.textContent = 'Save failed — check your connection';
            return false;
        }
    }

    function show(index) {
        if (!panels.length) return;
        current = Math.max(0, Math.min(index, panels.length - 1));
        panels.forEach((panel, i) => panel.classList.toggle('active', i === current));
        navButtons.forEach((button, i) => button.classList.toggle('current', i === current));
        document.getElementById('previous-question').disabled = current === 0;
        document.getElementById('next-question').disabled = current === panels.length - 1;
    }

    panels.forEach((panel, index) => {
        panel.addEventListener('change', () => {
            clearTimeout(debounceTimers.get(panel));
            debounceTimers.set(panel, setTimeout(() => save(panel), 180));
        });
        panel.addEventListener('input', () => {
            if (panel.dataset.type === 'short_answer' || panel.dataset.type === 'long_answer') {
                clearTimeout(debounceTimers.get(panel));
                debounceTimers.set(panel, setTimeout(() => save(panel), 600));
            }
        });
        navButtons[index]?.addEventListener('click', () => show(index));
    });

    document.getElementById('previous-question')?.addEventListener('click', () => show(current - 1));
    document.getElementById('next-question')?.addEventListener('click', () => show(current + 1));
    document.getElementById('clear-answer')?.addEventListener('click', async () => {
        const panel = panels[current];
        panel.querySelectorAll('input').forEach(input => { if (input.type === 'radio' || input.type === 'checkbox') input.checked = false; else input.value = ''; });
        panel.querySelectorAll('textarea').forEach(input => { input.value = ''; });
        await save(panel);
    });

    const submitForm = document.getElementById('submit-exam');
    async function submitAutomatically() {
        if (submitStarted) return;
        submitStarted = true;
        for (const panel of panels) {
            if (!await save(panel)) { submitStarted = false; return; }
        }
        submitForm.requestSubmit();
    }
    submitForm?.addEventListener('submit', async event => {
        if (!submitStarted) {
            event.preventDefault();
            if (window.confirm('Submit your exam? You will not be able to change answers afterward.')) {
                submitStarted = true;
                for (const panel of panels) {
                    if (!await save(panel)) { submitStarted = false; return; }
                }
                submitForm.submit();
            }
        }
    });

    function updateTimer() {
        const startedAt = Date.parse(timer.dataset.started);
        const durationMs = Number(timer.dataset.duration) * 60 * 1000;
        const secondsLeft = Math.max(0, Math.ceil((startedAt + durationMs - Date.now()) / 1000));
        timer.textContent = `${String(Math.floor(secondsLeft / 60)).padStart(2, '0')}:${String(secondsLeft % 60).padStart(2, '0')}`;
        if (secondsLeft === 0) submitAutomatically();
    }
    updateTimer();
    setInterval(updateTimer, 1000);
    show(0);

    async function logEvent(eventType) {
        try {
            await fetch(`/api/attempt/${attemptId}/event`, {
                method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRFToken': csrfToken },
                body: JSON.stringify({ event_type: eventType }), keepalive: true
            });
        } catch { /* Logging is best effort and never blocks an answer. */ }
    }
    document.addEventListener('visibilitychange', () => {
        if (document.hidden) logEvent('tab_hidden');
    });
    document.addEventListener('fullscreenchange', () => {
        if (!document.fullscreenElement) logEvent('fullscreen_exit');
    });
})();
