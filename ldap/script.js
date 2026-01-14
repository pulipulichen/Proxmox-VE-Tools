// --- State Management ---
const state = {
    detectedDomain: 'test.local',
    ouPaths: [], // Strings from textarea
    groups: [], // { type: 'dn'|'name', value: '' }
    users: [],  // { type: 'sAMAccountName'|..., value: '' }
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
const STORAGE_KEY = 'ldap_filter_generator_state';

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
    
    // Default value for OU Textarea if nothing saved
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

function ouPathToDn(path, domain) {
    if (!path) return '';
    let cleanPath = path.trim();
    if (!cleanPath) return '';

    // Standardize path
    let parts = cleanPath.split('/').filter(p => p.trim() !== '');

    // Logic: The first part is the domain.
    // Check if first part matches our detected domain (case-insensitive)
    if (parts.length > 0 && parts[0].toLowerCase() === domain.toLowerCase()) {
        parts.shift();
    }

    // Reverse: 資訊部 -> 總部
    let dnParts = parts.reverse().map(p => `OU=${p}`);

    // Append Domain DN
    dnParts.push(domainToDn(domain));

    return dnParts.join(',');
}

// --- UI Rendering: Groups ---
function renderGroupInputs() {
    el.groupContainer.innerHTML = '';
    if (state.groups.length === 0) {
        el.groupContainer.innerHTML = '<div class="text-xs text-slate-400 italic p-2 border border-dashed rounded">無群組限制</div>';
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
                class="flex-1 p-2 text-sm border border-slate-300 rounded focus:ring-1 focus:ring-blue-500 outline-none" 
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

// --- UI Rendering: Users ---
function renderUserInputs() {
    el.userContainer.innerHTML = '';
    if (state.users.length === 0) {
        el.userContainer.innerHTML = '<div class="text-xs text-slate-400 italic p-2 border border-dashed rounded">無特定帳號限制</div>';
    }
    state.users.forEach((usr, index) => {
        const div = document.createElement('div');
        div.className = 'flex gap-2 items-center';
        div.innerHTML = `
            <select onchange="updateUserType(${index}, this.value)" class="p-2 text-xs border rounded bg-slate-50 border-slate-300 w-28">
                <option value="sAMAccountName" ${usr.type === 'sAMAccountName' ? 'selected' : ''}>sAMAcc..</option>
                <option value="userPrincipalName" ${usr.type === 'userPrincipalName' ? 'selected' : ''}>UPN</option>
                <option value="uid" ${usr.type === 'uid' ? 'selected' : ''}>uid</option>
                <option value="employeeID" ${usr.type === 'employeeID' ? 'selected' : ''}>EmpID</option>
            </select>
            <input type="text" value="${usr.value}" oninput="updateUserValue(${index}, this.value)" 
                class="flex-1 p-2 text-sm border border-slate-300 rounded focus:ring-1 focus:ring-blue-500 outline-none" placeholder="value">
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

// --- Logic: Domain Detection & Filter ---
function updateAll() {
    const rawText = el.ouTextarea.value;
    state.ouPaths = rawText.split('\n').map(line => line.trim()).filter(line => line !== '');
    el.ouCountBadge.textContent = `${state.ouPaths.length} 筆有效路徑`;

    // 1. Detect Domain from first valid path
    let detectedDomain = 'example.com'; // Fallback
    if (state.ouPaths.length > 0) {
        // Take first line: "test.local/OU1/OU2" -> split -> "test.local"
        const firstPath = state.ouPaths[0];
        const parts = firstPath.split('/');
        if (parts.length > 0 && parts[0].includes('.')) {
            detectedDomain = parts[0];
        }
    }
    state.detectedDomain = detectedDomain;
    el.detectedDomainDisplay.textContent = detectedDomain;

    // 2. Calculate Base DN
    const rootDn = domainToDn(detectedDomain);
    el.previewBaseDn.textContent = rootDn;

    // 3. Resolve OUs to DNs
    const ouDns = state.ouPaths
        .map(p => ({ path: p, dn: ouPathToDn(p, detectedDomain) }));

    // 4. Build Filter Parts
    const conditions = [];

    // A. Groups
    state.groups.filter(g => g.value.trim()).forEach(g => {
        if (g.type === 'dn') {
            conditions.push(`(memberOf=${g.value.trim()})`);
        } else {
            conditions.push(`(memberOf=CN=${g.value.trim()},...)`);
        }
    });

    // B. Users
    state.users.filter(u => u.value.trim()).forEach(u => {
        conditions.push(`(${u.type}=${u.value.trim()})`);
    });

    // C. Strategy S2: OU Limitation inside Filter
    if (ouDns.length > 0) {
        ouDns.forEach(o => {
            conditions.push(`(distinguishedName=*,${o.dn})`);
        });
    }

    // 5. Assemble Filter
    const objectReq = `(objectCategory=person)(objectClass=user)`;
    let finalFilter = '';

    if (conditions.length === 0) {
        finalFilter = `(&${objectReq})`;
    } else {
        const orBlock = `(|${conditions.join('')})`;
        finalFilter = `(&${objectReq}${orBlock})`;
    }

    // 6. Outputs
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
