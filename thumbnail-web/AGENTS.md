## How to render Icons

Icon react components for each team are in [Icons](src/Icons).

### Example

```tsx
import * as Icons from 'Icons'

const Example = () => {
    return (
        <div>
            <Icons.TOR size={60} />
            <Icons.TOR /> // Default of 100px
            <Icons.TOR size={140} />
        </div>
    );
};

export default Example;
```


## Thumbnail rendering

`src/App.tsx` reads `home`, `away`, `image`, and `date` URL parameters. The date defaults to `Jan 1, 1970`; adjust `DATE_FONT_FAMILY` and `DATE_FONT_SIZE` there. `render-thumbnail.mjs` takes background image, home code, away code, date text, and output JPEG path in that order. It serves the built `dist/` assets locally and captures a 1280×720 JPEG with Playwright. Run `npm run build` after template changes. UnifiedApp calls the renderer through interactive zsh so NVM-provided Node is available.
