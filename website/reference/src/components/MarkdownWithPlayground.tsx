import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import RunCodeBlock from "./RunCodeBlock";

type Props = {
  markdown: string;
};

export default function MarkdownWithPlayground({ markdown }: Props) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        code(props) {
          const { className, children } = props;
          const text = String(children).replace(/\n$/, "");
          const isBlock = Boolean(className);
          const isFun = className?.includes("language-fun");

          if (isBlock && isFun) {
            return <RunCodeBlock initialCode={text} />;
          }

          if (isBlock) {
            return (
              <pre className="md-pre">
                <code>{text}</code>
              </pre>
            );
          }

          return <code className="md-inline-code">{children}</code>;
        },
      }}
    >
      {markdown}
    </ReactMarkdown>
  );
}
