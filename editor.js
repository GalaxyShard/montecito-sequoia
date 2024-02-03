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

    let editor = document.createElement("div");
    editor.classList.add("editor");
    editor.contentEditable = "true";
    editor.addEventListener("beforeinput", e => {
        // e.preventDefault();
    });
    editor.addEventListener("input", e => {
        // console.log(editor.value);
        // editor.innerHTML = editor.innerHTML.replace(/(\n|<br>){2,}/g, "\n");
    });
    // editor.addEventListener("paste", e => {
    //     console.log("paste, ", e);
    // });



    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    let bold = document.createElement("button");
    bold.classList.add("editor-bold");
    bold.textContent = "Bold";
    bold.addEventListener("click", e => {

    });

    let italic = document.createElement("button");
    italic.classList.add("editor-italic");
    italic.textContent = "Italic";
    italic.addEventListener("click", e => {

    });

    let link = document.createElement("button");
    link.classList.add("editor-link");
    link.textContent = "Link";
    link.addEventListener("click", e => {

    });

    let cancel = document.createElement("button");
    cancel.classList.add("editor-cancel");
    cancel.textContent = "Cancel";
    cancel.addEventListener("click", e => {
        let para = document.createElement("p");
        para.innerHTML = container.dataset.original;
        container.parentElement.replaceChild(para, container);
    });

    let save = document.createElement("button");
    save.classList.add("editor-save");
    save.textContent = "Save";
    save.addEventListener("click", e => {

    });



    removeHoverToolbar(para);
    container.dataset.original = para.innerHTML;
    let text = para.innerHTML.trim();
    text = text.replace(/(\n|<br>){2,}/g, "\n");

    editor.innerHTML = text;

    toolbar.append(bold, italic, link, cancel, save);
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