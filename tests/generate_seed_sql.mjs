// Generate SQL for 10 teachers and 23 class groups

const teachers = [
  { name: 'Farzan Noori' },
  { name: 'Mohaddisa Yasin' },
  { name: 'Ali Hassani' },
  { name: 'Shakila' },
  { name: 'Wahida Mohassel' },
  { name: 'Malali Naziri' },
  { name: 'Danish' },
  { name: 'Khatima' },
  { name: 'Tahira Sakhizada' },
  { name: 'Freshta' }
];

const classes = [
  // Farzan Noori (5 classes)
  { title: 'Special A2', teacher: 'Farzan Noori', start: '17:00', end: '18:00', fee: 2000 },
  { title: 'Special A2', teacher: 'Farzan Noori', start: '16:00', end: '17:00', fee: 1000 },
  { title: 'Special B1', teacher: 'Farzan Noori', start: '16:00', end: '17:00', fee: 2000 },
  { title: 'Special B1', teacher: 'Farzan Noori', start: '15:00', end: '16:00', fee: 1200 },
  { title: 'Special Class', teacher: 'Farzan Noori', start: '14:00', end: '15:00', fee: 2000 },

  // Wahida Mohassel (2 classes)
  { title: 'Intermadiate class', teacher: 'Wahida Mohassel', start: '15:00', end: '16:00', fee: 1500 },
  { title: 'Advance class', teacher: 'Wahida Mohassel', start: '14:00', end: '15:00', fee: 2000 },

  // Danish (4 classes)
  { title: 'Get Involved 1', teacher: 'Danish', start: '15:00', end: '16:00', fee: 1500 },
  { title: 'Get Involved 2', teacher: 'Danish', start: '17:00', end: '18:00', fee: 1500 },
  { title: 'Computer MS Excel', teacher: 'Danish', start: '16:00', end: '17:00', fee: 1500 },
  { title: 'Computer MS Excel', teacher: 'Danish', start: '14:00', end: '15:00', fee: 1500 },

  // Ali Hassani (2 classes)
  { title: 'Family & Friends 1', teacher: 'Ali Hassani', start: '16:00', end: '17:00', fee: 1000 },
  { title: 'Family & Friends 1 (Starter)', teacher: 'Ali Hassani', start: '15:00', end: '16:00', fee: 1000 },

  // Shakila (3 classes)
  { title: 'Family & Friends 2', teacher: 'Shakila', start: '14:00', end: '15:00', fee: 1000 },
  { title: 'Family & Friends 2', teacher: 'Shakila', start: '15:00', end: '16:00', fee: 1000 },
  { title: 'Family & Friends 4', teacher: 'Shakila', start: '17:00', end: '18:00', fee: 1000 },

  // Malali Naziri (3 classes)
  { title: 'Family & Friends 3', teacher: 'Malali Naziri', start: '16:00', end: '17:00', fee: 1000 },
  { title: 'Family & Friends 3', teacher: 'Malali Naziri', start: '15:00', end: '16:00', fee: 1000 },
  { title: 'Family & Friends 4', teacher: 'Malali Naziri', start: '17:00', end: '18:00', fee: 1000 },

  // Mohaddisa Yasin (2 classes)
  { title: 'Family & Friends 3', teacher: 'Mohaddisa Yasin', start: '14:00', end: '15:00', fee: 1000 },
  { title: 'Family & Friends 4', teacher: 'Mohaddisa Yasin', start: '16:00', end: '17:00', fee: 1000 },

  // Tahira Sakhizada (2 classes)
  { title: 'Grade 1,2,3', teacher: 'Tahira Sakhizada', start: '16:00', end: '18:00', fee: 1000 },
  { title: 'Grade 1', teacher: 'Tahira Sakhizada', start: '16:00', end: '17:00', fee: 1000 },

  // Khatima (1 class)
  { title: 'Family & Friends 2', teacher: 'Khatima', start: '15:00', end: '16:00', fee: 1000 },

  // Freshta (1 class)
  { title: 'Art', teacher: 'Freshta', start: '16:00', end: '17:00', fee: 1000 }
];

console.log('Teachers count:', teachers.length);
console.log('Class groups count:', classes.length);
