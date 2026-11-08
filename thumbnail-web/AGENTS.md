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

