(() => {
    const canvas = document.getElementById('performance-chart');
    if (!canvas) return;
    const tooltip = document.getElementById('chart-tooltip');
    const points = JSON.parse(canvas.dataset.points || '[]');
    const context = canvas.getContext('2d');
    let positions = [];

    function draw() {
        const box = canvas.getBoundingClientRect();
        const scale = window.devicePixelRatio || 1;
        canvas.width = Math.max(1, Math.round(box.width * scale));
        canvas.height = Math.round(240 * scale);
        context.setTransform(scale, 0, 0, scale, 0, 0);
        const width = box.width;
        const height = 240;
        const left = 34, right = 12, top = 12, bottom = 33;
        const plotWidth = Math.max(1, width - left - right);
        const plotHeight = height - top - bottom;
        context.clearRect(0, 0, width, height);
        context.font = '11px system-ui, sans-serif';
        context.textBaseline = 'middle';
        context.strokeStyle = '#253650';
        context.fillStyle = '#94a3b8';
        for (let mark = 0; mark <= 100; mark += 25) {
            const y = top + plotHeight * (1 - mark / 100);
            context.beginPath(); context.moveTo(left, y); context.lineTo(width - right, y); context.stroke();
            context.fillText(`${mark}%`, 0, y);
        }
        positions = points.map((point, index) => ({
            x: left + (points.length < 2 ? plotWidth / 2 : plotWidth * index / (points.length - 1)),
            y: top + plotHeight * (1 - Math.max(0, Math.min(100, Number(point.score))) / 100),
            point
        }));
        if (positions.length) {
            context.beginPath();
            positions.forEach((p, index) => index ? context.lineTo(p.x, p.y) : context.moveTo(p.x, p.y));
            context.lineWidth = 2.5; context.strokeStyle = '#06b6d4'; context.stroke();
            positions.forEach((p, index) => {
                context.beginPath(); context.arc(p.x, p.y, 4, 0, Math.PI * 2);
                context.fillStyle = index === positions.length - 1 ? '#3b82f6' : '#06b6d4'; context.fill();
                if (points.length <= 5 || index === 0 || index === points.length - 1) {
                    context.fillStyle = '#94a3b8';
                    const label = String(p.point.label).slice(0, 12);
                    context.textAlign = index === 0 ? 'left' : index === positions.length - 1 ? 'right' : 'center';
                    context.fillText(label, p.x, height - 12);
                }
            });
        }
    }

    canvas.addEventListener('pointermove', event => {
        if (!positions.length || !tooltip) return;
        const rect = canvas.getBoundingClientRect();
        const x = event.clientX - rect.left;
        const closest = positions.reduce((best, p) => Math.abs(p.x - x) < Math.abs(best.x - x) ? p : best);
        tooltip.textContent = `${closest.point.label}: ${closest.point.score}%`;
        tooltip.hidden = false;
    });
    canvas.addEventListener('pointerleave', () => { if (tooltip) tooltip.hidden = true; });
    draw();
    if ('ResizeObserver' in window) new ResizeObserver(draw).observe(canvas);
    else window.addEventListener('resize', draw);
})();
