/**
 * =============================================================================
 * HACKERAI BROWSER_SPY v3.0 - Headless Browser Intelligence Engine
 * =============================================================================
 * Imkoniyatlar:
 *   - DOM-based XSS skanerlash
 *   - Form ma'lumotlarini avtomatik yig'ish
 *   - Cookie/Session token ekstraksiyasi
 *   - Screenshot capture
 * Usage:    node browser_spy.js --target https://example.com
 * =============================================================================
 */

const puppeteer = require('puppeteer');
const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');
const { program } = require('commander');
const chalk = require('chalk');

const CONFIG = {
    TIMEOUT: 30000,
    SCREENSHOT_DIR: './screenshots',
    DUMP_DIR: './dumps',
    DELAY_MIN: 500,
    DELAY_MAX: 3000,
};

class CryptoHelper {
    static xorEncode(data, key = 'hackerai_nexus_key') {
        let result = '';
        for (let i = 0; i < data.length; i++) {
            result += String.fromCharCode(
                data.charCodeAt(i) ^ key.charCodeAt(i % key.length)
            );
        }
        return Buffer.from(result, 'binary').toString('base64');
    }
}

class XSSDetector {
    constructor(page) { this.page = page; }

    async scanForXSS() {
        const results = [];
        const payloads = [
            '<script>alert(1)</script>',
            '"><svg onload=alert(1)>',
            "'\"><img src=x onerror=alert(1)>",
        ];

        const url = this.page.url();
        const parsedUrl = new URL(url);
        const params = parsedUrl.searchParams;

        for (const [key, value] of params) {
            for (const payload of payloads) {
                const testUrl = new URL(url);
                testUrl.searchParams.set(key, payload);
                try {
                    const testPage = await this.page.browser().newPage();
                    await testPage.goto(testUrl.toString(), { waitUntil: 'networkidle0', timeout: 5000 });
                    const content = await testPage.content();
                    if (content.includes(payload)) {
                        results.push({ type: 'Reflected XSS', parameter: key, payload, url: testUrl.toString() });
                    }
                    await testPage.close();
                } catch(e) { /* skip */ }
            }
        }

        const domXSS = await this.page.evaluate(() => {
            const sinks = [];
            ['innerHTML', 'outerHTML', 'document.write', 'eval', 'src'].forEach(sink => {
                document.querySelectorAll(`[${sink}]`).forEach(el => {
                    sinks.push({ element: el.tagName, sink, value: el.getAttribute(sink)?.substring(0, 200) });
                });
            });
            return sinks;
        });

        if (domXSS.length > 0) results.push({ type: 'Potential DOM XSS', sinks: domXSS, url });
        return results;
    }
}

class FormGrabber {
    constructor(page) { this.page = page; }

    async extractForms() {
        return await this.page.evaluate(() => {
            const forms = [];
            document.querySelectorAll('form').forEach((form, idx) => {
                const formData = { index: idx, action: form.action, method: form.method, inputs: [] };
                form.querySelectorAll('input, textarea, select').forEach(input => {
                    formData.inputs.push({
                        type: input.type || 'text',
                        name: input.name || '',
                        value: input.value || '',
                        autocomplete: input.autocomplete || ''
                    });
                });
                forms.push(formData);
            });
            return forms;
        });
    }
}

class TokenExtractor {
    constructor(page) { this.page = page; }

    async extractAll() {
        const cookies = await this.page.cookies();
        const localStorage = await this.page.evaluate(() => {
            const data = {};
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                data[key] = localStorage.getItem(key);
            }
            return data;
        });

        const sessionTokens = await this.page.evaluate(() => {
            const tokens = [];
            const patterns = [
                /(?:csrf|xsrf|token|jwt|bearer|auth|session)[-_]?(?:token|key|id)?[:=]["']?([A-Za-z0-9._-]{20,})/gi,
                /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g,
            ];
            document.querySelectorAll('script').forEach(script => {
                patterns.forEach(pattern => {
                    const matches = script.textContent.matchAll(pattern);
                    for (const match of matches) {
                        tokens.push({ token: match[0].substring(0, 100), context: 'script' });
                    }
                });
            });
            return tokens;
        });

        return { cookies, localStorage, sessionTokens };
    }
}

class BrowserSpy {
    constructor(options) {
        this.options = options;
        this.results = {
            target: options.target,
            timestamp: new Date().toISOString(),
            forms: [], xss: [], tokens: [], screenshots: [],
        };
    }

    async randomDelay() {
        const ms = Math.random() * (CONFIG.DELAY_MAX - CONFIG.DELAY_MIN) + CONFIG.DELAY_MIN;
        await new Promise(r => setTimeout(r, ms));
    }

    async launch() {
        console.log(chalk.cyan('\n[.] Launching HACKERAI Browser Spy v3.0...'));
        this.browser = await puppeteer.launch({
            headless: 'new',
            args: [
                '--no-sandbox', '--disable-setuid-sandbox',
                '--disable-dev-shm-usage', '--disable-gpu',
                '--disable-web-security', '--window-size=1920,1080',
            ],
            ignoreHTTPSErrors: true,
        });
        this.page = await this.browser.newPage();
        await this.page.setViewport({ width: 1920, height: 1080 });
        console.log(chalk.yellow(`[>] Navigating to ${this.options.target}...`));
        await this.page.goto(this.options.target, { waitUntil: 'networkidle0', timeout: CONFIG.TIMEOUT });
        await this.randomDelay();
        console.log(chalk.green(`[V] Page loaded: ${await this.page.title()}`));
    }

    async run() {
        await this.launch();

        if (this.options.forms !== false) {
            console.log(chalk.cyan('\n[.] Phase 1: Form extraction...'));
            const formGrabber = new FormGrabber(this.page);
            this.results.forms = await formGrabber.extractForms();
            console.log(chalk.green(`  [V] Found ${this.results.forms.length} forms`));
            this.results.forms.forEach((form, idx) => {
                console.log(chalk.white(`  Form #${idx}: ${form.action} (${form.method})`));
                form.inputs.forEach(input => {
                    if (input.type === 'password') console.log(chalk.red(`    [SENSITIVE] ${input.name}=${input.value}`));
                    else if (input.value) console.log(chalk.gray(`    ${input.name}=${input.value}`));
                });
            });
        }

        if (this.options.xss) {
            console.log(chalk.cyan('\n[.] Phase 2: XSS scanning...'));
            const xssDetector = new XSSDetector(this.page);
            this.results.xss = await xssDetector.scanForXSS();
            if (this.results.xss.length > 0) {
                console.log(chalk.red(`  [!] Found ${this.results.xss.length} XSS vectors:`));
                this.results.xss.forEach(xss => console.log(chalk.red(`    [${xss.type}] ${xss.url}`)));
            } else {
                console.log(chalk.green('  [V] No XSS vectors detected'));
            }
        }

        if (this.options.tokens !== false) {
            console.log(chalk.cyan('\n[.] Phase 3: Token extraction...'));
            const tokenExtractor = new TokenExtractor(this.page);
            this.results.tokens = await tokenExtractor.extractAll();
            console.log(chalk.green(`  [V] Extracted ${this.results.tokens.cookies.length} cookies`));
            console.log(chalk.green(`  [V] Found ${this.results.tokens.sessionTokens.length} session tokens`));
            this.results.tokens.sessionTokens.forEach(token => {
                console.log(chalk.magenta(`  [TOKEN] ${token.context}: ${token.token.substring(0, 80)}...`));
            });
        }

        if (this.options.screenshot) {
            console.log(chalk.cyan('\n[.] Phase 4: Screenshot...'));
            await fs.mkdir(CONFIG.SCREENSHOT_DIR, { recursive: true });
            const filename = `screenshot_${Date.now()}.png`;
            const filepath = path.join(CONFIG.SCREENSHOT_DIR, filename);
            await this.page.screenshot({ path: filepath, fullPage: true });
            this.results.screenshots.push(filepath);
            console.log(chalk.green(`  [V] Saved: ${filepath}`));
        }

        await this.saveResults();
        await this.browser.close();
        console.log(chalk.cyan('\n[V] Browser Spy operation complete.\n'));
        return this.results;
    }

    async saveResults() {
        await fs.mkdir(CONFIG.DUMP_DIR, { recursive: true });
        const filename = `intel_${Date.now()}_${crypto.randomBytes(4).toString('hex')}.json`;
        const filepath = path.join(CONFIG.DUMP_DIR, filename);
        const encoded = { ...this.results, forms: CryptoHelper.xorEncode(JSON.stringify(this.results.forms)) };
        await fs.writeFile(filepath, JSON.stringify(encoded, null, 2));
        console.log(chalk.green(`[V] Encrypted results saved: ${filepath}`));
    }
}

program
    .name('browser_spy')
    .description('HACKERAI Browser Intelligence Engine v3.0')
    .version('3.0.0')
    .requiredOption('-t, --target <url>', 'Target URL')
    .option('--xss', 'Scan for XSS')
    .option('--screenshot', 'Capture screenshot')
    .option('--no-forms', 'Skip forms')
    .option('--no-tokens', 'Skip tokens');

program.parse(process.argv);
const options = program.opts();

(async () => {
    try {
        const spy = new BrowserSpy(options);
        const results = await spy.run();
        console.log(chalk.bold('\n=============== SUMMARY ==============='));
        console.log(chalk.white(`  Target:   ${results.target}`));
        console.log(chalk.white(`  Forms:    ${results.forms.length}`));
        console.log(chalk.white(`  XSS:      ${results.xss.length}`));
        console.log(chalk.white(`  Cookies:  ${results.tokens.cookies?.length || 0}`));
        console.log(chalk.white(`  Tokens:   ${results.tokens.sessionTokens?.length || 0}`));
        console.log(chalk.bold('========================================'));
    } catch (error) {
        console.error(chalk.red(`\n[!] Error: ${error.message}`));
        process.exit(1);
    }
})();
