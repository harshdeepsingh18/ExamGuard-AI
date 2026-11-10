(() => {
    const app = document.getElementById('exam-app');
    const button = document.getElementById('enable-camera');
    const video = document.getElementById('camera-preview');
    const status = document.getElementById('camera-status');
    if (!app || !button || !video) return;

    const token = document.querySelector('meta[name="csrf-token"]')?.content || '';
    const attemptId = app.dataset.attemptId;
    let stream;
    let loop;
    let lastState = null;

    async function logEvent(eventType) {
        try {
            await fetch(`/api/attempt/${attemptId}/event`, {
                method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRFToken': token },
                body: JSON.stringify({ event_type: eventType }), keepalive: true
            });
        } catch { /* Monitoring logs do not interrupt the exam. */ }
    }

    async function inspectFrame() {
        if (!stream || video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA) return;
        const canvas = document.createElement('canvas');
        const scale = Math.min(1, 640 / video.videoWidth);
        canvas.width = Math.round(video.videoWidth * scale);
        canvas.height = Math.round(video.videoHeight * scale);
        canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
        try {
            const response = await fetch(`/api/attempt/${attemptId}/face-check`, {
                method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRFToken': token },
                body: JSON.stringify({ frame: canvas.toDataURL('image/jpeg', 0.55) })
            });
            const result = await response.json();
            if (!response.ok) throw new Error(result.error || 'Detection unavailable');
            const state = result.face_count === 0 ? 'face_missing' : result.face_count > 1 ? 'multiple_faces' : 'face_present';
            status.textContent = state === 'face_present' ? 'One face detected' : state === 'face_missing' ? 'No face detected' : 'More than one face detected';
            if (state !== lastState && (state === 'face_missing' || state === 'multiple_faces')) logEvent(state);
            lastState = state;
        } catch (error) {
            status.textContent = error.message;
            if (lastState !== 'camera_error') logEvent('camera_error');
            lastState = 'camera_error';
        }
    }

    button.addEventListener('click', async () => {
        if (!navigator.mediaDevices?.getUserMedia) {
            status.textContent = 'Camera access requires a supported browser on HTTPS or localhost.';
            return;
        }
        button.disabled = true;
        status.textContent = 'Requesting camera permission…';
        try {
            stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 360 } }, audio: false });
            video.srcObject = stream;
            video.hidden = false;
            await video.play();
            status.textContent = 'Camera active; frames are processed without video storage.';
            await inspectFrame();
            loop = window.setInterval(inspectFrame, 5000);
        } catch {
            status.textContent = 'Camera permission was denied or the camera is unavailable.';
            await logEvent('camera_error');
            button.disabled = false;
        }
    });

    window.addEventListener('pagehide', () => {
        window.clearInterval(loop);
        stream?.getTracks().forEach(track => track.stop());
    });
})();
