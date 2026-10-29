'use strict';
// Gerätemodelle, die auf den GitHub-Macs als Simulator vorhanden sind, und ihre Gehäuseform.

window.MODELS = {
  '27': {
    iphone: ['iPhone 18 Pro', 'iPhone 18 Pro Max', 'iPhone Air', 'iPhone 17', 'iPhone 17e'],
    ipad: ['iPad Pro 13-inch (M5)', 'iPad Pro 11-inch (M5)', 'iPad Air 13-inch (M4)', 'iPad Air 11-inch (M4)', 'iPad (A16)', 'iPad mini (A17 Pro)'],
  },
  '26': {
    iphone: ['iPhone 17 Pro', 'iPhone 17 Pro Max', 'iPhone Air', 'iPhone 17', 'iPhone 17e'],
    ipad: ['iPad Pro 13-inch (M5)', 'iPad Pro 11-inch (M5)', 'iPad Air 13-inch (M4)', 'iPad Air 11-inch (M4)', 'iPad (A16)', 'iPad mini (A17 Pro)'],
  },
};

// Form des Gehäuses: Ecken des Displays und Rand in Anteilen der Display-Breite (Hochformat),
// Kamera-Aussparung (Dynamic Island oder Notch) in Punkten.
window.deviceShape = function deviceShape(model, role) {
  const name = model || '';
  if (role === 'ipad' || /iPad/.test(name)) {
    const mini = /mini/.test(name);
    return { radius: mini ? 0.028 : 0.0195, bezel: mini ? 0.06 : 0.042, cutout: null };
  }
  const notch = /\de$|SE/.test(name);
  return {
    radius: 0.137,
    bezel: /Air/.test(name) ? 0.04 : 0.048,
    cutout: notch
      ? { type: 'notch', width: 162, height: 33, top: 0 }
      : { type: 'island', width: 125, height: 37, top: 11 },
  };
};
