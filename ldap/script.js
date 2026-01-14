// --- State Management ---
const state = {
    detectedDomain: 'test.local',
    ouPaths: [], // Strings from textarea
    groups: [], // Additional groups from Section 2
    users: [],  // Specific users from Section 3
};

// --- DOM Elements ---
const el = {
    previewBaseDn: document.getElementById('previewBaseDn'),
    detectedDomainDisplay: document.getElementById('detectedDomainDisplay'),
    ouTextarea: document.getElementById('ouTextarea'),
    ouCountBadge: document.getElementById('ouCountBadge'),
    groupContainer: document.getElementById('groupContainer'),
    userContainer: document.getElementById('userContainer'),

    outFilterSingle: document.getElementById('outFilterSingle'),
    outFilterPretty: document.getElementById('outFilterPretty')
};

// --- Persistence ---
const STORAGE_KEY = 'ldap_group_filter_state_v2';

function saveToLocalStorage() {
    const dataToSave = {
        ouTextarea: el.ouTextarea.value,
        groups: state.groups,
        users: state.users
    };
    localStorage.setItem(STORAGE_KEY, JSON.stringify(dataToSave));
}

function loadFromLocalStorage() {
    const savedData = localStorage.getItem(STORAGE_KEY);
    if (savedData) {
        try {
            const parsed = JSON.parse(savedData);
            if (parsed.ouTextarea !== undefined) {
                el.ouTextarea.value = parsed.ouTextarea;
            }
            if (parsed.groups) {
                state.groups = parsed.groups;
            }
            if (parsed.users) {
                state.users = parsed.users;
            }
            return true;
        } catch (e) {
            console.error("Failed to load from localStorage", e);
        }
    }
    return false;
}

// --- Initialization ---
function init() {
    const loaded = loadFromLocalStorage();
    
    // Default value for Textarea if nothing saved
    if (!loaded) {
        el.ouTextarea.value = "test.local/總部/資訊部\ntest.local/總部/財務部";
    }

    renderGroupInputs();
    renderUserInputs();
    bindEvents();
    updateAll();
}

function bindEvents() {
    el.ouTextarea.addEventListener('input', () => {
        updateAll();
        saveToLocalStorage();
    });
}

// --- Logic: DN Conversion ---
function domainToDn(domain) {
    if (!domain) return '';
    return 'DC=' + domain.split('.').join(',DC=');
}

/**
 * Converts a path "domain/OU/OU/Group" into a Group DN.
 * Logic: Last segment is CN, middle segments are OUs.
 */
function pathToDn(path, domain) {
    if (!path) return '';
    let cleanPath = path.trim();
    if (!cleanPath) return '';

    // Standardize path
    let parts = cleanPath.split('/').filter(p => p.trim() !== '');

    // Logic: Remove domain from start if present
    if (parts.length > 0 && parts[0].toLowerCase() === domain.toLowerCase()) {
        parts.shift();
    }

    if (parts.length === 0) return '';

    // The LAST part is the Group Name (CN)
    const groupName = parts.pop(); 
    
    // The remaining parts are OUs, reversed (Bottom-up)
    let ouParts = parts.reverse().map(p => `OU=${p}`);

    // Construct DN: CN=Group,OU=...,DC=...
    const dnComponents = [`CN=${groupName}`, ...ouParts, domainToDn(domain)];
    
    return dnComponents.join(',');
}

// --- UI Rendering: Groups (Section 2) ---
function renderGroupInputs() {
    el.groupContainer.innerHTML = '';
    if (state.groups.length === 0) {
        el.groupContainer.innerHTML = '<div class="text-xs text-slate-400 italic p-2 border border-dashed rounded">無額外群組</div>';
    }
    state.groups.forEach((grp, index) => {
        const div = document.createElement('div');
        div.className = 'flex gap-2 items-center';
        div.innerHTML = `
            <select onchange="updateGroupType(${index}, this.value)" class="p-2 text-xs border rounded bg-slate-50 border-slate-300">
                <option value="dn" ${grp.type === 'dn' ? 'selected' : ''}>DN</option>
                <option value="name" ${grp.type === 'name' ? 'selected' : ''}>Name</option>
            </select>
            <input type="text" value="${grp.value}" oninput="updateGroupValue(${index}, this.value)" 
                class="flex-1 p-2 text-sm border border-slate-300 rounded focus:ring-1 focus:ring-indigo-500 outline-none" 
                placeholder="${grp.type === 'dn' ? 'CN=...,OU=...' : 'Group_Name'}">
            <button onclick="removeGroup(${index})" class="text-red-400 hover:text-red-600 px-2 font-bold">&times;</button>
        `;
        el.groupContainer.appendChild(div);
    });
}

function addGroupRow() {
    state.groups.push({ type: 'dn', value: '' });
    renderGroupInputs();
    updateAll();
    saveToLocalStorage();
}

function removeGroup(index) {
    state.groups.splice(index, 1);
    renderGroupInputs();
    updateAll();
    saveToLocalStorage();
}

window.updateGroupType = (index, type) => { 
    state.groups[index].type = type; 
    updateAll(); 
    renderGroupInputs(); 
    saveToLocalStorage();
};
window.updateGroupValue = (index, val) => { 
    state.groups[index].value = val; 
    updateAll(); 
    saveToLocalStorage();
};

// --- UI Rendering: Users (Section 3) ---
function renderUserInputs() {
    el.userContainer.innerHTML = '';
    if (state.users.length === 0) {
        el.userContainer.innerHTML = '<div class="text-xs text-slate-400 italic p-2 border border-dashed rounded">無特定帳號</div>';
    }
    state.users.forEach((usr, index) => {
        const div = document.createElement('div');
        div.className = 'flex gap-2 items-center';
        div.innerHTML = `
            <select onchange="updateUserType(${index}, this.value)" class="p-2 text-xs border rounded bg-slate-50 border-slate-300 w-28">
                <option value="sAMAccountName" ${usr.type === 'sAMAccountName' ? 'selected' : ''}>sAMAcc..</option>
                <option value="userPrincipalName" ${usr.type === 'userPrincipalName' ? 'selected' : ''}>UPN</option>
            </select>
            <input type="text" value="${usr.value}" oninput="updateUserValue(${index}, this.value)" 
                class="flex-1 p-2 text-sm border border-slate-300 rounded focus:ring-1 focus:ring-indigo-500 outline-none" placeholder="value">
            <button onclick="removeUser(${index})" class="text-red-400 hover:text-red-600 px-2 font-bold">&times;</button>
        `;
        el.userContainer.appendChild(div);
    });
}

function addUserRow() {
    state.users.push({ type: 'sAMAccountName', value: '' });
    renderUserInputs();
    updateAll();
    saveToLocalStorage();
}

function removeUser(index) {
    state.users.splice(index, 1);
    renderUserInputs();
    updateAll();
    saveToLocalStorage();
}

window.updateUserType = (index, type) => { 
    state.users[index].type = type; 
    updateAll(); 
    saveToLocalStorage();
};
window.updateUserValue = (index, val) => { 
    state.users[index].value = val; 
    updateAll(); 
    saveToLocalStorage();
};

// --- Logic: Main Generation ---
function updateAll() {
    const rawText = el.ouTextarea.value;
    state.ouPaths = rawText.split('\n').map(line => line.trim()).filter(line => line !== '');
    el.ouCountBadge.textContent = `${state.ouPaths.length} 筆路徑`;

    // 1. Detect Domain from first valid path
    let detectedDomain = 'example.com';
    if (state.ouPaths.length > 0) {
        const firstPath = state.ouPaths[0];
        const parts = firstPath.split('/');
        if (parts.length > 0 && parts[0].includes('.')) {
            detectedDomain = parts[0];
        }
    }
    state.detectedDomain = detectedDomain;
    el.detectedDomainDisplay.textContent = detectedDomain;
    el.previewBaseDn.textContent = domainToDn(detectedDomain);

    // 2. Build Filter Conditions
    const conditions = [];

    // A. Groups from Path List (Section 1)
    state.ouPaths.forEach(path => {
        const fullDn = pathToDn(path, detectedDomain);
        if (fullDn) {
            conditions.push(`(memberOf=${fullDn})`);
        }
    });

    // B. Additional Groups (Section 2)
    state.groups.filter(g => g.value.trim()).forEach(g => {
        if (g.type === 'dn') {
            conditions.push(`(memberOf=${g.value.trim()})`);
        } else {
            // Fuzzy name match - usually risky in LDAP filters without DN, but provided as option
            // Often better to use CN={name}*, but here we assume user knows what they do or puts full CN
            conditions.push(`(memberOf=CN=${g.value.trim()},*)`); 
        }
    });

    // C. Specific Users (Section 3)
    state.users.filter(u => u.value.trim()).forEach(u => {
        conditions.push(`(${u.type}=${u.value.trim()})`);
    });

    // 3. Assemble Filter
    // Standard AD User object category
    const objectReq = `(objectCategory=person)(objectClass=user)`;
    let finalFilter = '';

    if (conditions.length === 0) {
        // If nothing specified, just return all users (safest default for "generator", though risky for "firewall")
        finalFilter = `(&${objectReq})`;
    } else {
        // OR logic for all allowed groups/users
        const orBlock = `(|${conditions.join('')})`;
        finalFilter = `(&${objectReq}${orBlock})`;
    }

    // 4. Outputs
    el.outFilterSingle.value = finalFilter;
    el.outFilterPretty.textContent = formatLdapFilter(finalFilter);
}

function formatLdapFilter(filter) {
    let indent = 0;
    let output = '';
    for (let i = 0; i < filter.length; i++) {
        const char = filter[i];
        if (char === '(') {
            output += '\n' + '  '.repeat(indent) + char;
            indent++;
        } else if (char === ')') {
            indent--;
            output += char;
        } else {
            output += char;
        }
    }
    return output.trim();
}

// --- Helpers ---
window.addGroupRow = addGroupRow;
window.removeGroup = removeGroup;
window.addUserRow = addUserRow;
window.removeUser = removeUser;

window.copyToClipboard = (id) => {
    const el = document.getElementById(id);
    el.select();
    document.execCommand('copy');
};

// Start
init();