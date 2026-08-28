'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const htmlPath = path.join(__dirname, '..', 'public', 'index.html');
const html = fs.readFileSync(htmlPath, 'utf8');
const scriptPattern = /<script(?![^>]*\bsrc=)(?![^>]*type=["']application\/ld\+json["'])[^>]*>([\s\S]*?)<\/script>/gi;

let match;
let index = 0;
while ((match = scriptPattern.exec(html)) !== null) {
    index++;
    new vm.Script(match[1], { filename: `public/index.html:inline-script-${index}` });
}

if (index === 0) throw new Error('没有找到可检查的内联 JavaScript');
console.log(`已检查 ${index} 个内联 JavaScript 块`);
