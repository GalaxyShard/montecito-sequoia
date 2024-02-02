/**
 *
 * @licstart  The following is the entire license notice for the 
 *  JavaScript code in this page
 *
 * Copyright (C) 2023-2024 Dominic Adragna
 *
 * The JavaScript code in this page is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 * 
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * @licend  The above is the entire license notice
 * for the JavaScript code in this page
 *
 */

let isEditing = false;
function removeHoverToolbar(para) {
    let buttons = para.getElementsByClassName("editor-button");
    if (buttons) {
        buttons[0].remove();
    }
}
function createEditorBox(para) {
    let container = document.createElement("div");
    container.classList.add("editor-container");

    let editor = document.createElement("textarea");
    editor.classList.add("editor");



    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    // consider using a markdown-like format instead of buttons?
    let bold = document.createElement("button");
    bold.classList.add("editor-bold");
    bold.textContent = "Bold";

    let strong = document.createElement("button");
    strong.classList.add("editor-strong");
    strong.textContent = "Emphasis";

    let italic = document.createElement("button");
    italic.classList.add("editor-italic");
    italic.textContent = "Italic";

    let em = document.createElement("button");
    em.classList.add("editor-em");
    em.textContent = "Emphasis";

    let save = document.createElement("button");
    save.classList.add("editor-save");
    save.textContent = "Save";



    removeHoverToolbar(para);
    let text = para.innerHTML.trim();
    
    
    editor.textContent = text;

    toolbar.append(bold, strong, italic, em, save);
    container.append(editor, toolbar);
    para.parentElement.replaceChild(container, para);
}

for (let p of document.getElementsByTagName("p")) {
    p.addEventListener("mouseenter", _ => {

        let editButton = document.createElement("button");
        editButton.textContent = "Edit";
        editButton.classList.add("editor-button");

        editButton.addEventListener("click", _ => {
            if (isEditing) {
                return;
            }
            // isEditing = true;
            createEditorBox(p);
        });
        
        p.append(editButton);
    });
    p.addEventListener("mouseleave", _ => {
        removeHoverToolbar(p);
    });
}