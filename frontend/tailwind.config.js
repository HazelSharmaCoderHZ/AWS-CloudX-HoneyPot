/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './pages/**/*.{js,jsx}',
    './components/**/*.{js,jsx}',
    './app/**/*.{js,jsx}',
  ],
  theme: {
    extend: {
      colors: {
        navy: {
          950: '#0a0e1a',
          900: '#0f1626',
          800: '#151f38',
          700: '#1c2a4a',
          600: '#243556',
        },
      },
    },
  },
  plugins: [],
}
