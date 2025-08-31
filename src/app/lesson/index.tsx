interface Props {
  id: string
}

export default function Lesson({ id }: Props) {
  return (
    <div>
      <h1>Lesson {id}</h1>
      <p>Content coming soon.</p>
    </div>
  )
}
