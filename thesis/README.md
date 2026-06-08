# Исходные файлы для курсового проекта (LaTeX)

Каталог `thesis/sources/` содержит исходные файлы LaTeX для сборки пояснительной записки (отчета) и слайдов презентации.

## Как скомпилировать файлы в PDF:

Для сборки документов вам потребуется дистрибутив LaTeX (например, TeX Live, MacTeX или MiKTeX) с установленным компилятором `pdflatex` или `xelatex`.

### Вариант 1: Через командную строку (Linux / macOS / Windows CLI)

Сборка отчета (`report.pdf`):
```bash
pdflatex -output-directory=../ sources/report.tex
pdflatex -output-directory=../ sources/report.tex
```
*(Запуск команды дважды необходим для правильного построения оглавления и перекрестных ссылок).*

Сборка слайдов (`slides.pdf`):
```bash
pdflatex -output-directory=../ sources/slides.tex
pdflatex -output-directory=../ sources/slides.tex
```

### Вариант 2: С помощью утилиты latexmk (рекомендуется)
```bash
latexmk -pdf -outdir=../ sources/report.tex
latexmk -pdf -outdir=../ sources/slides.tex
```

### Вариант 3: Использование онлайн-редакторов (Overleaf)
1. Создайте новый проект на [Overleaf](https://www.overleaf.com).
2. Загрузите файлы из папки `sources/`.
3. Выберите основной компилятор (pdfLaTeX) и соберите документы в веб-интерфейсе.
