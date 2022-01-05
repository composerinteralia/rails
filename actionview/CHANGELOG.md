*   Fix and add protections for XSS in `ActionView::Helpers` and `ERB::Util`.

    Escape dangerous characters in names of tags and names of attributes in the
    tag helpers, following the XML specification. Rename the option
    `:escape_attributes` to `:escape`, to simplify by applying the option to the
    whole tag.

    *Álvaro Martín Fraguas*

*   Ensure models passed to `form_for` attempt to call `to_model`.

    *Sean Doyle*

Please check [7-0-stable](https://github.com/rails/rails/blob/7-0-stable/actionview/CHANGELOG.md) for previous changes.
