'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const scriptPattern = /<script(?![^>]*\bsrc=)(?![^>]*type=["']application\/ld\+json["'])[^>]*>([\s\S]*?)<\/script>/gi;

function checkInlineScripts(html, filename = 'public/index.html') {
    let match;
    let index = 0;
    scriptPattern.lastIndex = 0;
    while ((match = scriptPattern.exec(html)) !== null) {
        index++;
        new vm.Script(match[1], { filename: `${filename}:inline-script-${index}` });
    }
    return index;
}

if (require.main === module) {
    const htmlPath = path.join(__dirname, '..', 'public', 'index.html');
    const html = fs.readFileSync(htmlPath, 'utf8');
    const count = checkInlineScripts(html);
    console.log(`已检查 ${count} 个内联 JavaScript 块`);
}

module.exports = { checkInlineScripts };
