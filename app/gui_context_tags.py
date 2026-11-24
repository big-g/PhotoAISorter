# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Photo AI Sorter contributors — see NOTICE

"""Dialog for managing tag sets — unified category + description editor."""

from __future__ import annotations

import tkinter.messagebox as messagebox

import customtkinter as ctk

from app.context_tags import (
    Tag,
    TagSet,
    load_tag_store,
    save_tag_store,
)


class TagSetsDialog(ctk.CTkToplevel):
    """Unified editor: each tag = output folder + optional description for the model."""

    def __init__(self, parent: ctk.CTkBaseClass, on_save: None | callable = None):
        super().__init__(parent)
        self.title("Tag Sets")
        self.geometry("720x600")
        self.resizable(True, True)
        self._on_save_callback = on_save
        self._store = load_tag_store()
        self._build()
        self.after(100, self.lift)

    def _build(self) -> None:
        top = ctk.CTkFrame(self, fg_color="transparent")
        top.pack(fill="x", padx=10, pady=(10, 4))

        ctk.CTkLabel(top, text="Set:", width=50).pack(side="left")
        self._set_var = ctk.StringVar(value="")
        names = [s.name for s in self._store.sets] or ["(none)"]
        self._set_combo = ctk.CTkComboBox(
            top, values=names, variable=self._set_var,
            width=200, state="readonly",
            command=self._on_set_selected,
        )
        self._set_combo.pack(side="left", padx=4)
        if self._store.sets:
            active = self._store.active_set or self._store.sets[0].name
            self._set_var.set(active)
        else:
            self._set_var.set("(none)")

        ctk.CTkButton(top, text="+ New", width=80, command=self._add_set).pack(side="left", padx=4)
        ctk.CTkButton(top, text="Delete set", width=110,
                      fg_color=("gray75", "gray35"), command=self._delete_set).pack(side="left", padx=4)

        self._active_cb_var = ctk.BooleanVar(value=False)
        self._active_cb = ctk.CTkCheckBox(
            top, text="Active", variable=self._active_cb_var,
            command=self._on_active_toggled,
        )
        self._active_cb.pack(side="right", padx=8)

        hint = ctk.CTkLabel(
            self,
            text=(
                "Each tag is a sorting folder. The optional description helps the model "
                "know what to look for in the image. If blank, the model receives only the tag name.\n"
                "Active набор используется в режиме «Свой список»."
            ),
            wraplength=680,
            justify="left",
            text_color=("gray38", "gray62"),
        )
        hint.pack(anchor="w", padx=12, pady=(2, 6))

        self._tags_frame = ctk.CTkScrollableFrame(self, height=350)
        self._tags_frame.pack(fill="both", expand=True, padx=8, pady=4)

        btn_row = ctk.CTkFrame(self, fg_color="transparent")
        btn_row.pack(fill="x", padx=8, pady=(4, 10))
        ctk.CTkButton(btn_row, text="+ Add tag", width=130, command=self._add_tag).pack(side="left", padx=4)
        ctk.CTkButton(btn_row, text="Save", width=100, command=self._save).pack(side="right", padx=4)

        self._refresh_active_checkbox()
        self._refresh_tags()

    def _current_set(self) -> TagSet | None:
        name = self._set_var.get()
        for s in self._store.sets:
            if s.name == name:
                return s
        return None

    def _on_set_selected(self, _val: str = "") -> None:
        self._refresh_active_checkbox()
        self._refresh_tags()

    def _refresh_active_checkbox(self) -> None:
        name = self._set_var.get()
        self._active_cb_var.set(name == self._store.active_set and name != "(none)")

    def _on_active_toggled(self) -> None:
        name = self._set_var.get()
        if name == "(none)":
            self._active_cb_var.set(False)
            return
        if self._active_cb_var.get():
            self._store.active_set = name
        else:
            self._store.active_set = ""

    def _refresh_tags(self) -> None:
        for w in self._tags_frame.winfo_children():
            w.destroy()
        tag_set = self._current_set()
        if not tag_set:
            ctk.CTkLabel(
                self._tags_frame, text="Select or create a tag set.",
                text_color=("gray50", "gray50"),
            ).pack(pady=20)
            return
        for idx, tag in enumerate(tag_set.tags):
            self._render_tag_row(idx, tag)

    def _render_tag_row(self, idx: int, tag: Tag) -> None:
        row = ctk.CTkFrame(self._tags_frame, fg_color=("gray88", "gray20"), corner_radius=6)
        row.pack(fill="x", padx=2, pady=2)

        inner = ctk.CTkFrame(row, fg_color="transparent")
        inner.pack(fill="x", padx=6, pady=4)

        ctk.CTkLabel(inner, text="Tag:", width=30).pack(side="left")
        key_entry = ctk.CTkEntry(inner, width=160, placeholder_text="folder_name")
        key_entry.pack(side="left", padx=(2, 8))
        key_entry.insert(0, tag.key)
        key_entry.bind("<FocusOut>", lambda e, i=idx, w=key_entry: self._update_key(i, w.get()))

        ctk.CTkLabel(inner, text="Description:", width=72).pack(side="left")
        desc_entry = ctk.CTkEntry(inner, placeholder_text="(optional) what to look for in photos")
        desc_entry.pack(side="left", fill="x", expand=True, padx=(2, 6))
        desc_entry.insert(0, tag.description)
        desc_entry.bind("<FocusOut>", lambda e, i=idx, w=desc_entry: self._update_desc(i, w.get()))

        ctk.CTkButton(
            inner, text="✕", width=28, height=28,
            fg_color=("gray75", "gray35"),
            command=lambda i=idx: self._delete_tag(i),
        ).pack(side="right")

    def _update_key(self, idx: int, val: str) -> None:
        tag_set = self._current_set()
        if tag_set and idx < len(tag_set.tags):
            tag_set.tags[idx].key = val.strip().lower().replace(" ", "_")

    def _update_desc(self, idx: int, val: str) -> None:
        tag_set = self._current_set()
        if tag_set and idx < len(tag_set.tags):
            tag_set.tags[idx].description = val.strip()

    def _add_tag(self) -> None:
        tag_set = self._current_set()
        if not tag_set:
            messagebox.showwarning("No set", "Create or select a tag set first.")
            return
        tag_set.tags.append(Tag(key="", description=""))
        self._refresh_tags()

    def _delete_tag(self, idx: int) -> None:
        tag_set = self._current_set()
        if tag_set and idx < len(tag_set.tags):
            tag_set.tags.pop(idx)
            self._refresh_tags()

    def _add_set(self) -> None:
        dialog = ctk.CTkInputDialog(text="Name of new set:", title="New tag set")
        name = (dialog.get_input() or "").strip()
        if not name:
            return
        for s in self._store.sets:
            if s.name == name:
                messagebox.showwarning("Already exists", f"Set '{name}' already exists.")
                return
        self._store.sets.append(TagSet(name=name, tags=[]))
        names = [s.name for s in self._store.sets]
        self._set_combo.configure(values=names)
        self._set_var.set(name)
        self._refresh_active_checkbox()
        self._refresh_tags()

    def _delete_set(self) -> None:
        name = self._set_var.get()
        if not name or name == "(none)":
            return
        self._store.sets = [s for s in self._store.sets if s.name != name]
        if self._store.active_set == name:
            self._store.active_set = ""
        names = [s.name for s in self._store.sets] or ["(none)"]
        self._set_combo.configure(values=names)
        self._set_var.set(names[0] if self._store.sets else "(none)")
        self._refresh_active_checkbox()
        self._refresh_tags()

    def _save(self) -> None:
        for s in self._store.sets:
            s.tags = [t for t in s.tags if t.key.strip()]
        save_tag_store(self._store)
        if self._on_save_callback:
            self._on_save_callback()
        messagebox.showinfo("Saved", "Tag Sets сохранены.")
