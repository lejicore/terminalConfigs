// an example to create a new mapping `ctrl-y`
api.mapkey('<ctrl-y>', 'Show me the money', function() {
    api.Front.showPopup('a well-known phrase uttered by characters in the 1996 film Jerry Maguire (Escape to close).');
});

// an example to replace `T` with `gt`, click `Default mappings` to see how `T` works.
//api.map('f', 'F');

// an example to remove mapkey `Ctrl-i`
//api.unmap('<ctrl-i>');

// set theme
settings.theme = `
.sk_theme {
    font-family: Input Sans Condensed, Charcoal, sans-serif;
    font-size: 10pt;
    background: #24272e;
    color: #abb2bf;
}
.sk_theme tbody {
    color: #fff;
}
.sk_theme input {
    color: #d0d0d0;
}
.sk_theme .url {
    color: #61afef;
}
.sk_theme .annotation {
    color: #56b6c2;
}
.sk_theme .omnibar_highlight {
    color: #528bff;
}
.sk_theme .omnibar_timestamp {
    color: #e5c07b;
}
.sk_theme .omnibar_visitcount {
    color: #98c379;
}
.sk_theme #sk_omnibarSearchResult ul li:nth-child(odd) {
    background: #303030;
}
.sk_theme #sk_omnibarSearchResult ul li.focused {
    background: #3e4452;
}
#sk_status, #sk_find {
    font-size: 20pt;
}`;
// click `Save` button to make above settings to take effect.</ctrl-i></ctrl-y>
// Forced blur + escape to normal mode (Tridactyl C-, equivalent)
api.imapkey('<Ctrl-;>', 'Force blur and exit insert mode', function () {
    const el = document.activeElement;
    if (el && typeof el.blur === 'function') {
        el.blur();
    }
    // Explicitly force Surfingkeys back to normal mode
    Normal.enter();
});

api.imapkey('<Ctrl-,>', 'Blur chat input and exit insert mode', () => {
    let active = document.activeElement;
    if (active) {
        // If focus is inside an iframe, active will be the iframe element
        if (active.tagName === 'IFRAME') {
            active.blur();  // blur the iframe element to drop focus from it
        } else {
            active.blur();
            // If the element is a shadow host with open shadow DOM:
            if (active.shadowRoot && active.shadowRoot.activeElement) {
                active.shadowRoot.activeElement.blur();  // blur inner shadow element if accessible
            }
        }
    }
    Normal.enter();
});

api.addCommand('zoom', 'Set zoom percentage', function(args) {
    // const percent = parseInt(String(args).trim(), 10);
    // //api.Front.showPopup(`percent is: ${percent}`);
    // if (!isNaN(percent)) {
    //     //RUNTIME('setZoom', { zoomFactor: percent / 100 });
    //     document.body.style.zoom = `${percent}%`;
    // }
    document.body.style.zoom = `${args}%`;
});

api.addCommand('zoomyes', 'Set zoom percentage', function() {
    //RUNTIME('setZoom', { zoomFactor: 0.8 });
    //api.Front.executeCommand('setZoom', {zoomFactor: 0.8});
    document.body.style.zoom = '80%';
});
