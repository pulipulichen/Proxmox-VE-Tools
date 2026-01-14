// --- Copy to Clipboard Helper ---
function copyText(text) {
    const tempInput = document.createElement("textarea");
    tempInput.value = text;
    document.body.appendChild(tempInput);
    tempInput.select();
    document.execCommand("copy");
    document.body.removeChild(tempInput);
    
    // Simple toast notification simulation
    const btn = event.target.closest('button');
    const originalContent = btn.innerHTML;
    btn.innerHTML = '<i class="fas fa-check mr-1"></i>已複製';
    btn.classList.remove('bg-gray-700');
    btn.classList.add('bg-green-600');
    setTimeout(() => {
        btn.innerHTML = originalContent;
        btn.classList.add('bg-gray-700');
        btn.classList.remove('bg-green-600');
    }, 1500);
}

function copyOutput() {
    const text = document.getElementById('cmdOutput').value;
    if(text) copyText(text);
}

function copyBase64Result() {
    const text = document.getElementById('base64Output').value;
    if(text) copyText(text);
}

// --- LDAP Command Generator ---
function generateCommand() {
    const hostRaw = document.getElementById('ldapHost').value.trim();
    const baseDnRaw = document.getElementById('baseDn').value.trim();
    const bindDnRaw = document.getElementById('bindDn').value.trim();
    const targetIdRaw = document.getElementById('targetId').value.trim();
    const idAttr = document.getElementById('idAttr').value;

    // Save to localStorage
    localStorage.setItem('ldap_host', hostRaw);
    localStorage.setItem('ldap_baseDn', baseDnRaw);
    localStorage.setItem('ldap_bindDn', bindDnRaw);
    localStorage.setItem('ldap_targetId', targetIdRaw);
    localStorage.setItem('ldap_idAttr', idAttr);

    const host = hostRaw || "ldap_server_ip";
    const baseDn = baseDnRaw || "dc=example,dc=com";
    const bindDn = bindDnRaw;
    const targetId = targetIdRaw || "username";

    let cmd = `ldapsearch -x`;
    
    // Add Host
    if (host.includes('://')) {
        cmd += ` -H ${host}`;
    } else {
        cmd += ` -H ldap://${host}`;
    }

    // Add Bind DN (if exists)
    if (bindDn) {
        cmd += ` -D "${bindDn}" -W`; // -W prompts for password
    }

    // Add Base DN
    cmd += ` -b "${baseDn}"`;

    // Add Search Filter
    // For AD, sAMAccountName is standard. For OpenLDAP, uid is standard.
    cmd += ` "(${idAttr}=${targetId})"`;

    document.getElementById('cmdOutput').value = cmd;
}

// Load saved values from localStorage
function loadSavedValues() {
    const host = localStorage.getItem('ldap_host');
    const baseDn = localStorage.getItem('ldap_baseDn');
    const bindDn = localStorage.getItem('ldap_bindDn');
    const targetId = localStorage.getItem('ldap_targetId');
    const idAttr = localStorage.getItem('ldap_idAttr');

    if (host !== null) document.getElementById('ldapHost').value = host;
    if (baseDn !== null) document.getElementById('baseDn').value = baseDn;
    if (bindDn !== null) document.getElementById('bindDn').value = bindDn;
    if (targetId !== null) document.getElementById('targetId').value = targetId;
    if (idAttr !== null) document.getElementById('idAttr').value = idAttr;

    generateCommand();
}

// Initialize with defaults
window.onload = loadSavedValues;


// --- Base64 Logic ---

// Helper to handle UTF-8 strings properly in Base64
function utf8_to_b64(str) {
    try {
        return window.btoa(unescape(encodeURIComponent(str)));
    } catch (e) {
        return "Error: Encoding failed.";
    }
}

function b64_to_utf8(str) {
    try {
        return decodeURIComponent(escape(window.atob(str)));
    } catch (e) {
        return "Error: Invalid Base64 string.";
    }
}

function decodeBase64() {
    let input = document.getElementById('base64Input').value.trim();
    
    if (!input) return;

    // Common cleanup: remove "memberOf:: " or "description:: " if user copied the whole line from ldapsearch
    // Regex handles "attribute:: <base64>" pattern
    input = input.replace(/^[a-zA-Z0-9]+::\s*/, "");
    
    // Handle multiple lines if input contains newlines
    const lines = input.split('\n');
    const results = lines.map(line => {
        line = line.trim();
        // Strip prefix again for each line just in case
        line = line.replace(/^[a-zA-Z0-9]+::\s*/, "");
        if(!line) return "";
        return b64_to_utf8(line);
    });

    document.getElementById('base64Output').value = results.join('\n');
}

function encodeBase64() {
    const input = document.getElementById('base64Input').value;
    if (!input) return;

    // Handle multiple lines
    const lines = input.split('\n');
    const results = lines.map(line => {
        if(!line) return "";
        return utf8_to_b64(line);
    });

    document.getElementById('base64Output').value = results.join('\n');
}

function clearBase64() {
    document.getElementById('base64Input').value = '';
    document.getElementById('base64Output').value = '';
}
