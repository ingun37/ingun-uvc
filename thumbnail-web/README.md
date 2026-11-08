# thumbnail-web

It's a 1280x720 sized template page for creating video thumbnails.

It takes four URL parameters.

- `home` - Home team
- `away` - Away team
- `image` - Image URL
- `date` - Centered date text (defaults to `Jan 1, 1970`)

Change `DATE_FONT_FAMILY` and `DATE_FONT_SIZE` in `src/App.tsx` to adjust the date style.

It will render a 1280x720 sized HTML,
and the thumbnail is retrievable by taking a screenshot.
