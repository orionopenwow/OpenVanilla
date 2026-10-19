fetch('icons.svg').then(r => r.text()).then(svg => {
      document.body.insertAdjacentHTML('afterbegin', svg);
      const box = document.getElementById('icons');
      document.querySelectorAll('symbol').forEach(s => {
        box.insertAdjacentHTML('beforeend', `<div><svg><use href="#${s.id}"/></svg>${s.id.slice(2)}</div>`);
      });
    }).catch(() => {});
